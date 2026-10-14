import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import reader

OWNER='10000000-0000-4000-8000-000000000001'
KEY='10000000-0000-4000-8000-000000000002'
UPLOAD='10000000-0000-4000-8000-000000000003'
OBJECT='10000000-0000-4000-8000-000000000004'
class Fake:
    def __init__(self):self.signed=[];self.heads=[]
    def list_objects_v2(self,**args):
        assert args['Prefix']=='media-hub/encrypted-catalogs/'
        return {'Contents':[{'Key':f'media-hub/encrypted-catalogs/{KEY}/{UPLOAD}.bin','Size':1000},{'Key':'media-hub/encrypted-catalogs/invalid/file.bin','Size':123}]}
    def head_object(self,**args):self.heads.append(args['Key']);return {'VersionId':'cipher-version','ContentLength':1000}
    def generate_presigned_url(self,operation,**args):self.signed.append(args);return 'https://private.s3.ap-northeast-1.amazonaws.com/opaque'
class EncryptedReaderTests(unittest.TestCase):
    def setUp(self):
        self.fake=Fake(); self.environment=patch.dict(os.environ,{'BUCKET':'test-bucket','OWNER_SUB':OWNER});self.environment.start();self.addCleanup(self.environment.stop)
        self.client=patch('reader.client',return_value=self.fake);self.client.start();self.addCleanup(self.client.stop)
    def call(self,path,owner=OWNER,method='GET'):
        return reader.handler({'rawPath':path,'requestContext':{'http':{'method':method},'authorizer':{'jwt':{'claims':{'sub':owner} if owner else {}}}}},None)
    def test_owner_only_index_is_opaque_and_read_only(self):
        self.assertEqual(self.call('/encrypted-library',owner=None)['statusCode'],401)
        self.assertEqual(self.call('/encrypted-library',owner=KEY)['statusCode'],403)
        self.assertEqual(self.call('/encrypted-library',method='POST')['statusCode'],405)
        value=json.loads(self.call('/encrypted-library')['body'])
        self.assertEqual(value,[{'id':UPLOAD,'keyID':KEY,'cipherBytes':1000}]);self.assertNotIn('name',value[0])
    def test_urls_are_scoped_version_pinned_and_no_store(self):
        path=f'/encrypted-objects/{KEY}/{UPLOAD}/{OBJECT}/url'
        self.assertEqual(self.call(path)['statusCode'],200)
        self.assertEqual(self.fake.heads[0],f'media-hub/encrypted-catalogs/{KEY}/{UPLOAD}.bin')
        params=self.fake.signed[0]
        self.assertEqual(params['Params']['Key'],f'media-hub/encrypted-objects/{KEY}/{UPLOAD}/{OBJECT}.bin')
        self.assertEqual(params['Params']['VersionId'],'cipher-version');self.assertEqual(params['ExpiresIn'],300)
        self.assertEqual(params['Params']['ResponseCacheControl'],'private, no-store')
        self.assertEqual(self.call(f'/encrypted-objects/{KEY}/{UPLOAD}/../url')['statusCode'],400)
    def test_missing_catalog_does_not_issue_a_url(self):
        with patch.object(self.fake,'head_object',side_effect=Exception('PRIVATE_URL SECRET')):
            result=self.call(f'/encrypted-objects/{KEY}/{UPLOAD}/{OBJECT}/url')
        self.assertEqual(result['statusCode'],502);self.assertEqual(self.fake.signed,[]);self.assertNotIn('SECRET',result['body'])
