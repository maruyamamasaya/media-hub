import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.folder_privacy import FolderPrivacy, security
from vault.folder_upload import FolderUploads
from vault.service import VaultError
from vault.app import create_app
from fastapi.testclient import TestClient
from test_folder_upload import FakeCloud

class PrivateCloud(FakeCloud):
    def __init__(self):
        super().__init__()
        self.settings = security.empty_settings()
        self.install_settings()
    def install_settings(self):
        raw=json.dumps(self.settings).encode(); self.objects[security.KEY]=raw
    def download(self,key,version,target):
        target.write_bytes(self.objects[key]); return {'ETag':'test-etag'}
    def head(self,key):
        result=super().head(key)
        if result: result['ETag']='test-etag'
        return result
    def put(self,path,key,digest,content_type,etag=None):
        if etag is not None:
            assert etag == 'test-etag'
            assert key == security.KEY
            assert base64.b64encode(hashlib.sha256(path.read_bytes()).digest()).decode() == digest
            self.objects[key] = path.read_bytes()
            return
        return super().put(path,key,digest,content_type)

class FolderPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.source=self.root/'source'; self.source.mkdir()
        (self.source/'secret.jpg').write_bytes(b'original')
        self.cloud=PrivateCloud()
        self.uploads=FolderUploads(self.root/'data',client_factory=lambda *_:self.cloud)
        summary=self.uploads.scan({'path':str(self.source),'bucket':'test-private-bucket','profile':'test','region':'ap-northeast-1'})
        self.uploads.upload(summary['id'])
        self.plan=self.uploads.read(summary['id'])
        self.folder=self.plan['folders'][0]['id']
        self.privacy=FolderPrivacy(self.uploads)
    def test_shared_save_hidden_read_and_media_guard(self):
        originals={key:value for key,value in self.cloud.objects.items() if '/originals/' in key}
        self.privacy.set({'planId':self.plan['id'],'folderId':self.folder,'password':'012345','confirmSave':True},'')
        raw=self.cloud.objects[security.KEY]
        self.assertNotIn(b'012345',raw)
        self.assertEqual(self.privacy.library(''),[])
        self.assertEqual(self.privacy.plans(''),[])
        with self.assertRaises(VaultError): self.privacy.authorize(self.plan['id'],self.plan['items'][0]['id'],'')
        token=self.privacy.unlock({'password':'012345'},'')['token']
        self.assertEqual(len(self.privacy.library(token)),1)
        self.privacy.authorize(self.plan['id'],self.plan['items'][0]['id'],token)
        self.privacy.set({'planId':self.plan['id'],'folderId':self.folder,'password':None,'confirmSave':True},token)
        self.assertEqual(len(self.privacy.library('')),1)
        self.assertEqual(originals,{key:value for key,value in self.cloud.objects.items() if '/originals/' in key})
    def test_config_failure_no_bypass_and_unconfirmed_save_denied(self):
        with self.assertRaises(VaultError): self.privacy.set({'confirmSave':False},'')
        self.cloud.objects[security.KEY]=b'broken'
        with self.assertRaises(VaultError): self.privacy.library('')
    def test_relock_cookie_boundary(self):
        app=create_app(self.root/'api',privacy_enabled=True)
        app.state.folder_uploads.client_factory=lambda *_:self.cloud
        # Attach a real test plan to this app's data path.
        app.state.folder_uploads.save(self.plan)
        self.cloud.settings['locks']=[security.make_lock(self.plan['rootId'],self.folder,'012345')]
        self.cloud.install_settings()
        with TestClient(app,base_url='http://127.0.0.1') as client:
            self.assertEqual(client.get('/api/v1/folder-library').json(),[])
            response=client.post('/api/v1/folder-locks/unlock',json={'password':'012345'})
            self.assertEqual(response.status_code,200)
            self.assertIn('HttpOnly',response.headers['set-cookie'])
            self.assertEqual(len(client.get('/api/v1/folder-library').json()),1)
            client.post('/api/v1/folder-locks/relock')
            self.assertEqual(client.get('/api/v1/folder-library').json(),[])
