import base64
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.encrypted_upload import EncryptedUploads, ROOT
from vault.service import VaultError
from vault.app import create_app
from test_folder_upload import FakeCloud, validate_contract

KEY_ID = '10000000-0000-4000-8000-000000000001'
KEY = b'\x21' * 32

class EncryptedUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / 'SecretFolder'; self.source.mkdir()
        from PIL import Image
        Image.new('RGBA', (40, 30), (10, 20, 30, 90)).save(self.source / 'PrivatePhoto.png')
        self.cloud = FakeCloud()
        self.service = EncryptedUploads(self.root / 'data', lambda *args: self.cloud)
        if not self.service.helper.is_file():
            self.skipTest('Build MediaHubCrypto first')
    def scan(self):
        return self.service.scan({'path':str(self.source),'bucket':'test-bucket','profile':'test','region':'ap-northeast-1'})
    def prepare(self):
        value = self.scan(); raw = self.service.uploads.read(value['id']); raw['keyID'] = KEY_ID; self.service.uploads.save(raw)
        return value
    def test_sixteen_mib_catalog_helper_and_duplicate_reader(self):
        import uuid
        from vault.upload_duplicates import catalogs
        from catalog_limits import MAX_CATALOG_BYTES, MAX_ENCRYPTED_CATALOG_BYTES
        identity, folder = str(uuid.uuid4()), str(uuid.uuid4())
        value = {'schemaVersion': 1, 'id': identity, 'keyID': KEY_ID, 'name': 'Boundary',
                 'folders': [{'id': folder, 'name': 'Folder', 'parentId': None}], 'items': []}
        base = len(json.dumps(value).encode())
        value['name'] += 'x' * (MAX_CATALOG_BYTES - base)
        source, encrypted = self.root / 'catalog.json', self.root / 'catalog.bin'
        source.write_text(json.dumps(value))
        self.service.encrypt(source, encrypted, identity, KEY)
        self.assertEqual(encrypted.stat().st_size, MAX_ENCRYPTED_CATALOG_BYTES)
        restored = self.service.decrypt_catalog(encrypted, identity, KEY_ID, KEY)
        self.assertEqual(restored, value)
        object_key = f'media-hub/encrypted-catalogs/{KEY_ID}/{identity}.bin'
        self.cloud.objects[object_key] = encrypted.read_bytes()
        result = list(catalogs(self.cloud, f'media-hub/encrypted-catalogs/{KEY_ID}/', self.root,
                              decode=lambda path, upload: self.service.decrypt_catalog(path, upload, KEY_ID, KEY)))
        self.assertEqual(result[0][0]['id'], identity)
        value['name'] += 'x'; source.write_text(json.dumps(value)); encrypted.unlink()
        self.service.encrypt(source, encrypted, identity, KEY)
        with self.assertRaises(VaultError): self.service.decrypt_catalog(encrypted, identity, KEY_ID, KEY)

    def test_scan_and_discard_are_local_and_normal_keys_are_absent(self):
        plan = self.scan(); validate_contract(plan, 'FolderUpload')
        self.assertEqual(self.cloud.puts, [])
        self.assertNotIn('objectKey', self.service.uploads.read(plan['id'])['items'][0])
        self.service.uploads.discard(plan['id']); self.assertEqual(self.service.list(), [])
        self.assertTrue((self.source / 'PrivatePhoto.png').is_file())
    def test_only_ciphertext_original_thumbnail_and_catalog_are_uploaded(self):
        plan = self.prepare(); source = (self.source / 'PrivatePhoto.png').read_bytes()
        self.service.upload(plan['id'], KEY_ID, KEY)
        raw = self.service.uploads.read(plan['id']); self.assertEqual(raw['state'], 'complete', raw['error'])
        self.assertEqual(len(self.cloud.puts), 3)
        for name, data in self.cloud.objects.items():
            self.assertTrue(name.startswith(('media-hub/encrypted-objects/', 'media-hub/encrypted-catalogs/')))
            self.assertNotIn('SecretFolder', name); self.assertNotIn('PrivatePhoto', name)
            self.assertTrue(data.startswith(b'MHSEAL01'))
            self.assertNotIn(b'PrivatePhoto', data); self.assertNotIn(b'SecretFolder', data)
            self.assertNotEqual(data, source)
        self.assertEqual((self.source / 'PrivatePhoto.png').read_bytes(), source)
        self.assertEqual(list(self.service.uploads.root.glob('sealed-staging-*')), [])
        self.assertNotIn(base64.b64encode(KEY).decode(), self.service.uploads.path(plan['id']).read_text())
    def test_retry_does_not_reupload_cipher_objects_or_plaintext(self):
        plan = self.prepare(); self.cloud.fail_catalog = False
        original_put = self.cloud.put
        def fail(path, key, digest, mime, etag=None):
            if '/encrypted-catalogs/' in key:
                raise VaultError('cloud_error','test failure',502)
            return original_put(path,key,digest,mime,etag)
        with patch.object(self.cloud, 'put', side_effect=fail):
            self.service.upload(plan['id'], KEY_ID, KEY)
        self.assertEqual(self.service.uploads.read(plan['id'])['state'], 'failed')
        self.assertEqual(len(self.cloud.puts), 2)
        self.service.upload(plan['id'], KEY_ID, KEY)
        self.assertEqual(self.service.uploads.read(plan['id'])['state'], 'complete')
        self.assertEqual(len(self.cloud.puts), 3)
    def test_source_change_never_uploads_and_confirmation_is_required(self):
        plan = self.prepare(); (self.source / 'PrivatePhoto.png').write_bytes(b'changed')
        self.service.upload(plan['id'], KEY_ID, KEY)
        self.assertEqual(self.service.uploads.read(plan['id'])['state'], 'failed'); self.assertEqual(self.cloud.puts, [])
        with self.assertRaises(VaultError): self.service.start(plan['id'], {'confirmUpload':False,'keyID':KEY_ID,'masterKey':base64.b64encode(KEY).decode()})
    def test_key_stays_out_of_journal_and_retry_rejects_another_key(self):
        plan = self.scan()
        body = {'confirmUpload':True,'keyID':KEY_ID,'masterKey':base64.b64encode(KEY).decode()}
        with patch('vault.encrypted_upload.threading.Thread'):
            self.service.start(plan['id'], body)
        self.service.uploads.running.clear()
        self.assertNotIn(body['masterKey'], self.service.uploads.path(plan['id']).read_text())
        body['masterKey'] = base64.b64encode(b'\x22'*32).decode()
        with self.assertRaises(VaultError): self.service.start(plan['id'], body)
    def test_api_local_boundary_and_separate_history(self):
        app = create_app(self.root/'api', cloud_only=True)
        client = TestClient(app); headers={'host':'127.0.0.1:8765'}
        body={'path':str(self.source),'bucket':'test-bucket','profile':'test','region':'ap-northeast-1'}
        self.assertEqual(client.post('/api/v1/encrypted-uploads/scan', json=body, headers={'host':'evil.invalid'}).status_code,403)
        plan=client.post('/api/v1/encrypted-uploads/scan', json=body, headers=headers).json()
        self.assertEqual(len(client.get('/api/v1/encrypted-uploads',headers=headers).json()),1)
        self.assertEqual(client.get('/api/v1/folder-uploads',headers=headers).json(),[])
        response=client.post(f'/api/v1/encrypted-uploads/{plan["id"]}/start',json={'confirmUpload':True,'keyID':KEY_ID,'masterKey':'wrong'},headers=headers)
        self.assertEqual(response.status_code,400); self.assertNotIn('wrong',response.text)
