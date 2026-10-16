"""SDK transport, conditional receipts and resume keep the original safeguards."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import boto3
from botocore.response import StreamingBody
from botocore.stub import Stubber, ANY
from botocore.exceptions import EndpointConnectionError
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.s3_pooled import S3Pooled
from vault.folder_upload import FolderUploads
from vault.service import VaultError
from test_folder_upload import FakeCloud


class PooledTests(unittest.TestCase):
    def setUp(self):
        self.sdk=boto3.client('s3',region_name='ap-northeast-1',aws_access_key_id='test',aws_secret_access_key='test')
        self.addCleanup(self.sdk.close)
        self.stub=Stubber(self.sdk);self.stub.activate();self.addCleanup(self.stub.deactivate)
        self.cloud=S3Pooled('test-bucket','test-profile','ap-northeast-1',sdk=self.sdk)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'body';self.path.write_bytes(b'original')
        self.digest=base64.b64encode(hashlib.sha256(b'original').digest()).decode()
    def put_params(self):
        return dict(Bucket='test-bucket',Key='key',Body=ANY,ChecksumAlgorithm='SHA256',ChecksumSHA256=self.digest,
                    ContentType='image/jpeg',ServerSideEncryption='AES256',StorageClass='STANDARD',IfNoneMatch='*')
    def head_params(self):
        return dict(Bucket='test-bucket',Key='key',ChecksumMode='ENABLED')
    def test_versioned_checked_receipt_avoids_head_and_keeps_conditional_put(self):
        self.stub.add_response('put_object',dict(ChecksumSHA256=self.digest,VersionId='v1',ETag='etag'),self.put_params())
        remote=self.cloud.put_verified(self.path,'key',self.digest,'image/jpeg')
        self.assertEqual(remote['ContentLength'],8)
        self.assertEqual(remote['VersionId'],'v1');self.stub.assert_no_pending_responses()
    def test_conflict_reconciles_only_matching_content_and_missing_is_not_success(self):
        for matching in (True,False):
            self.stub.add_client_error('put_object','PreconditionFailed',http_status_code=412,expected_params=self.put_params())
            self.stub.add_response('head_object',dict(ContentLength=8,ChecksumSHA256=self.digest if matching else 'bad'),self.head_params())
            if matching:self.cloud.put_verified(self.path,'key',self.digest,'image/jpeg')
            else:
                with self.assertRaises(VaultError) as error:self.cloud.put_verified(self.path,'key',self.digest,'image/jpeg')
                self.assertEqual(error.exception.code,'integrity')
        self.stub.add_client_error('head_object','404',http_status_code=404,expected_params=self.head_params())
        self.assertIsNone(self.cloud.head('key'))
    def test_uncertain_put_reconciles_existing_object_without_second_put(self):
        self.stub.add_client_error('put_object','InternalError',http_status_code=500,expected_params=self.put_params())
        self.stub.add_response('head_object',dict(ContentLength=8,ChecksumSHA256=self.digest,VersionId='v1'),self.head_params())
        self.assertEqual(self.cloud.put_verified(self.path,'key',self.digest,'image/jpeg')['VersionId'],'v1')
        self.stub.assert_no_pending_responses()

    def test_missing_receipt_fields_fall_back_to_head_but_bad_checksum_is_rejected(self):
        self.stub.add_response('put_object',{},self.put_params())
        self.stub.add_response('head_object',dict(ContentLength=8,ChecksumSHA256=self.digest),self.head_params())
        self.cloud.put_verified(self.path,'key',self.digest,'image/jpeg')
        self.stub.add_response('put_object',dict(ChecksumSHA256='bad'),self.put_params())
        with self.assertRaises(VaultError) as error:self.cloud.put_verified(self.path,'key',self.digest,'image/jpeg')
        self.assertEqual(error.exception.code,'integrity')
    def test_download_consumes_closes_body_and_preserves_version_and_checksum(self):
        body=StreamingBody(io.BytesIO(b'original'),8)
        self.stub.add_response('get_object',dict(Body=body,ContentLength=8),dict(Bucket='test-bucket',Key='key',VersionId='v1',ChecksumMode='ENABLED'))
        self.cloud.download('key','v1',self.path)
        self.assertEqual(self.path.read_bytes(),b'original');self.assertTrue(body._raw_stream.closed)
    def test_authentication_and_multipart_expiry_error_mapping(self):
        for code,expected in [('ExpiredToken','aws_login_required'),('NoSuchUpload','multipart_expired')]:
            self.stub.add_client_error('head_object',code,expected_params=self.head_params())
            with self.assertRaises(VaultError) as error:self.cloud.head('key')
            self.assertEqual(error.exception.code,expected)
    def test_multipart_parameter_types_and_manifest_mapping(self):
        self.stub.add_response('list_parts',dict(Parts=[]),dict(Bucket='test-bucket',Key='key',UploadId='u',PartNumberMarker=2))
        self.cloud.call('list-parts','--key','key','--upload-id','u','--part-number-marker','2')
        manifest=Path(self.temp.name)/'parts.json';manifest.write_text(json.dumps({'Parts':[{'PartNumber':1,'ETag':'e'}]}))
        self.stub.add_response('complete_multipart_upload',{},dict(Bucket='test-bucket',Key='key',UploadId='u',MultipartUpload={'Parts':[{'PartNumber':1,'ETag':'e'}]},IfNoneMatch='*'))
        self.cloud.call('complete-multipart-upload','--key','key','--upload-id','u','--multipart-upload','file://'+str(manifest),'--if-none-match','*')
    def test_new_upload_skips_preflight_heads_but_resume_reconciles(self):
        class Checked(FakeCloud):
            direct_put=True
            def __init__(self):super().__init__();self.heads=[]
            def head(self,key):self.heads.append(key);return super().head(key)
            def put_verified(self,path,key,digest,mime):
                self.put(path,key,digest,mime)
                return FakeCloud.head(self,key)
        cloud=Checked();source=Path(self.temp.name)/'photos';source.mkdir()
        from PIL import Image
        Image.new('RGB',(8,8)).save(source/'a.jpg')
        service=FolderUploads(Path(self.temp.name)/'library',lambda *args:cloud)
        plan=service.scan(dict(path=str(source),bucket='test-bucket',profile='test-profile',region='ap-northeast-1'))
        service.upload(plan['id'])
        self.assertEqual(service.read(plan['id'])['state'],'complete')
        self.assertFalse(any('/originals/' in k or '/thumbnails/' in k for k in cloud.heads))
        # A previous interrupted/old plan must inspect existing originals first.
        saved=service.read(plan['id']);saved['state']='failed';saved['items'][0]['state']='pending';service.save(saved)
        cloud.heads.clear();service.upload(plan['id'])
        self.assertTrue(any('/originals/' in k for k in cloud.heads))
