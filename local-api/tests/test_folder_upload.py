import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.folder_upload import FolderUploads, S3CLI, signature
from vault.service import VaultError
from vault.app import create_app
from test_vault import validate_contract


class FakeCloud:
    def __init__(self):
        self.objects = {}
        self.puts = []
        self.fail_catalog = False
        self.corrupt = False
        self.after_put = None

    def download(self, key, version, target):
        target.write_bytes(self.objects[key])

    def verify_private(self):
        pass

    def head(self, key):
        if key not in self.objects:
            return None
        data = self.objects[key]
        return {'ContentLength': len(data), 'ChecksumSHA256': 'bad' if self.corrupt else base64.b64encode(hashlib.sha256(data).digest()).decode(), 'VersionId': 'v1'}

    def put(self, path, key, digest, mime):
        if self.fail_catalog and '/catalogs/' in key:
            raise VaultError('cloud_error', 'catalog failed', 502)
        if key in self.objects:
            raise AssertionError('overwrite')
        data = path.read_bytes()
        assert base64.b64encode(hashlib.sha256(data).digest()).decode() == digest
        self.objects[key] = data
        self.puts.append(key)
        if self.after_put:
            self.after_put()


class FolderUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'Photos'
        (self.source / 'Trip' / 'Empty').mkdir(parents=True)
        (self.source / 'Trip' / 'image.png').write_bytes(b'image-bytes')
        (self.source / 'movie.MP4').write_bytes(b'movie-bytes')
        self.cloud = FakeCloud()
        self.service = FolderUploads(self.root / 'library', lambda *args: self.cloud)

    def scan(self):
        return self.service.scan({'path': str(self.source), 'bucket': 'test-bucket', 'profile': 'test-profile', 'region': 'ap-northeast-1'})

    def test_hierarchy_empty_folder_contract_and_local_only_scan(self):
        (self.source / '.secret.png').write_bytes(b'secret')
        (self.source / 'ignore.txt').write_bytes(b'ignored')
        (self.source / 'link.png').symlink_to(self.source / 'movie.MP4')
        plan = self.scan()
        validate_contract(plan, 'FolderUpload')
        self.assertEqual(len(plan['folders']), 3)
        self.assertEqual(len(plan['items']), 2)
        self.assertEqual(plan['skipped'], 3)
        self.assertEqual(self.cloud.puts, [])
        raw = self.service.read(plan['id'])
        self.assertTrue(all('Trip' not in i['objectKey'] for i in raw['items']))

    def test_upload_keeps_sources_and_commits_private_catalog(self):
        plan = self.scan()
        self.service.upload(plan['id'])
        result = self.service.read(plan['id'])
        self.assertEqual(result['state'], 'complete')
        self.assertTrue((self.source / 'movie.MP4').exists())
        catalog = json.loads(self.cloud.objects[self.cloud.puts[-1]])
        self.assertEqual(len(catalog['folders']), 3)
        self.assertNotIn('sourceRoot', catalog)
        self.assertNotIn(str(self.source), json.dumps(catalog))
        self.assertEqual(self.service.public(result)['completed'], 2)
        # Re-running the same plan is safe even after a lost completion response.
        self.service.upload(plan['id'])
        self.assertEqual(len(self.cloud.puts), 3)

    def test_changed_original_never_uploaded(self):
        plan = self.scan()
        (self.source / 'movie.MP4').write_bytes(b'new-movie')
        self.service.upload(plan['id'])
        self.assertEqual(self.service.read(plan['id'])['state'], 'failed')
        self.assertEqual(self.cloud.puts, [])

    def test_integrity_failure_never_commits_catalog(self):
        plan = self.scan()
        self.cloud.corrupt = True
        self.service.upload(plan['id'])
        self.assertEqual(self.service.read(plan['id'])['state'], 'failed')
        self.assertFalse(any('/catalogs/' in key for key in self.cloud.puts))
        self.assertTrue((self.source / 'movie.MP4').exists())

    def test_catalog_retry_does_not_resend_originals(self):
        plan = self.scan()
        self.cloud.fail_catalog = True
        self.service.upload(plan['id'])
        self.assertEqual(self.service.read(plan['id'])['state'], 'failed')
        self.cloud.fail_catalog = False
        self.service.upload(plan['id'])
        self.assertEqual(self.service.read(plan['id'])['state'], 'complete')
        self.assertEqual(len(self.cloud.puts), 3)

    def test_pause_after_current_file_requires_manual_resume(self):
        plan = self.scan()
        self.cloud.after_put = lambda: self.service.pause(plan['id'])
        self.service.upload(plan['id'])
        self.assertEqual(self.service.read(plan['id'])['state'], 'paused')
        self.assertEqual(len(self.cloud.puts), 1)
        self.cloud.after_put = None
        raw = self.service.read(plan['id'])
        raw['stop'] = False
        self.service.save(raw)
        self.service.upload(plan['id'])
        self.assertEqual(self.service.read(plan['id'])['state'], 'complete')

    def test_restart_does_not_connect_or_auto_resume(self):
        plan = self.scan()
        raw = self.service.read(plan['id'])
        raw['state'] = 'uploading'
        self.service.save(raw)
        service = FolderUploads(self.root / 'library', lambda *args: self.fail('unexpected cloud call'))
        self.assertEqual(service.read(plan['id'])['state'], 'interrupted')

    def test_repeat_scan_retains_folder_and_asset_ids(self):
        first, second = self.scan(), self.scan()
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual(first['folders'], second['folders'])
        self.assertEqual(first['items'], second['items'])

    def test_confirmation_and_id_validation(self):
        plan = self.scan()
        with self.assertRaises(VaultError):
            self.service.start(plan['id'], {})
        with self.assertRaises(VaultError):
            self.service.start(plan['id'], {'confirmUpload': 1})
        with self.assertRaises(VaultError):
            self.service.read('../roots')

    def test_start_endpoint_runs_manual_background_upload(self):
        import time
        app = create_app(self.root / 'background-library')
        app.state.folder_uploads.client_factory = lambda *args: self.cloud
        client = TestClient(app)
        headers = {'host': '127.0.0.1:8765'}
        plan = client.post('/api/v1/folder-uploads/scan', json={'path': str(self.source), 'bucket': 'test-bucket', 'profile': 'test-profile', 'region': 'ap-northeast-1'}, headers=headers).json()
        endpoint = '/api/v1/folder-uploads/' + plan['id']
        self.assertEqual(client.post(endpoint + '/start', json={}, headers=headers).status_code, 400)
        response = client.post(endpoint + '/start', json={'confirmUpload': True}, headers=headers)
        self.assertEqual(response.status_code, 200)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            result = client.get(endpoint, headers=headers).json()
            if result['state'] != 'uploading':
                break
            time.sleep(0.01)
        self.assertEqual(result['state'], 'complete')
        validate_contract(result, 'FolderUpload')

    def test_replaced_subdirectory_link_is_not_followed(self):
        plan = self.scan()
        import shutil
        target = self.root / 'outside'
        target.mkdir()
        (target / 'image.png').write_bytes(b'private-outside-file')
        shutil.rmtree(self.source / 'Trip')
        (self.source / 'Trip').symlink_to(target, target_is_directory=True)
        self.service.upload(plan['id'])
        self.assertEqual(self.service.read(plan['id'])['state'], 'failed')
        self.assertFalse(any('/catalogs/' in key for key in self.cloud.puts))

    def test_api_boundaries_and_contract(self):
        client = TestClient(create_app(self.root / 'api-library'))
        body = {'path': str(self.source), 'bucket': 'test-bucket', 'profile': 'test-profile', 'region': 'ap-northeast-1'}
        response = client.post('/api/v1/folder-uploads/scan', json=body, headers={'host': '127.0.0.1:8765'})
        self.assertEqual(response.status_code, 200)
        validate_contract(response.json(), 'FolderUpload')
        self.assertEqual(client.post('/api/v1/folder-uploads/scan', json=body, headers={'host': 'evil.invalid'}).status_code, 403)
        self.assertEqual(client.post('/api/v1/folder-uploads/scan', json=body, headers={'host': '127.0.0.1:8765', 'origin': 'https://evil.invalid'}).status_code, 403)

    def test_missing_vs_permission_and_conditional_put(self):
        cli = S3CLI('test-bucket', 'profile', 'ap-northeast-1')
        import subprocess
        with patch('vault.folder_upload.subprocess.run', return_value=subprocess.CompletedProcess([], 1, '', 'An error occurred (404)')):
            self.assertIsNone(cli.head('key'))
        with patch('vault.folder_upload.subprocess.run', return_value=subprocess.CompletedProcess([], 1, '', 'AccessDenied')):
            with self.assertRaises(VaultError):
                cli.head('key')
        with patch('vault.folder_upload.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '{}', '')) as run:
            cli.put(Path('source'), 'key', 'digest', 'video/mp4')
            self.assertIn('--if-none-match', run.call_args.args[0])
            self.assertNotIn('shell', run.call_args.kwargs)

class CloudLibraryTests(unittest.TestCase):
    setUp = FolderUploadTests.setUp
    scan = FolderUploadTests.scan
    def make_saved(self):
        import io
        from PIL import Image
        data = io.BytesIO()
        Image.new('RGB', (12, 12), 'red').save(data, format='PNG')
        (self.source / 'Trip' / 'image.png').write_bytes(data.getvalue())
        plan = self.scan()
        self.service.upload(plan['id'])
        return self.service.read(plan['id'])

    def test_new_unfinished_scan_does_not_hide_saved_folder(self):
        saved = self.make_saved()
        self.scan()
        library = self.service.library()
        self.assertEqual([p['id'] for p in library], [saved['id']])

    def test_original_always_uses_s3_even_when_mac_source_exists(self):
        plan = self.make_saved()
        image = next(i for i in plan['items'] if i['name'] == 'image.png')
        (self.source / 'Trip' / 'image.png').write_bytes(b'changed-local-original')
        with self.assertRaises(VaultError):
            self.service.media(plan['id'], image['id'], True)
        original, _, _ = self.service.media(plan['id'], image['id'])
        self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), image['sha256'])
        self.assertEqual((self.source / 'Trip' / 'image.png').read_bytes(), b'changed-local-original')

    def test_missing_local_original_downloads_verified_version(self):
        plan = self.make_saved()
        image = next(i for i in plan['items'] if i['name'] == 'image.png')
        (self.source / 'Trip' / 'image.png').unlink()
        calls = []
        def download(key, version, target):
            calls.append((key, version))
            target.write_bytes(self.cloud.objects[key])
        self.cloud.download = download
        with self.assertRaises(VaultError):
            self.service.media(plan['id'], image['id'], True)
        self.assertEqual(calls, [])
        path, _, _ = self.service.media(plan['id'], image['id'])
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), image['sha256'])
        self.assertEqual(calls, [(image['objectKey'], 'v1')])
        self.service.media(plan['id'], image['id'])
        self.assertEqual(len(calls), 1)

    def test_preview_uses_only_verified_cache_preserves_alpha_and_never_downloads(self):
        from PIL import Image
        Image.new('RGBA', (640, 240), (40, 80, 120, 96)).save(self.source / 'Trip' / 'image.png')
        plan = self.scan()
        self.service.upload(plan['id'])
        plan = self.service.read(plan['id'])
        item = next(i for i in plan['items'] if i['name'] == 'image.png')
        with patch.object(self.cloud, 'download', wraps=self.cloud.download) as download:
            with self.assertRaises(VaultError):
                self.service.media(plan['id'], item['id'], True)
            download.assert_not_called()
            original, _, _ = self.service.media(plan['id'], item['id'])
            before = original.read_bytes()
            preview, mime, _ = self.service.media(plan['id'], item['id'], True)
            self.assertEqual(download.call_count, 1)
            self.assertEqual(mime, 'image/png')
            with Image.open(preview) as image:
                self.assertEqual(image.size, (320, 120))
                self.assertEqual(image.getpixel((0, 0))[3], 96)
            self.assertEqual(original.read_bytes(), before)
            self.service.media(plan['id'], item['id'], True)
            self.assertEqual(download.call_count, 1)

    def test_preview_rejects_corrupt_cache_without_fetching_original(self):
        plan = self.make_saved()
        item = next(i for i in plan['items'] if i['name'] == 'image.png')
        original, _, _ = self.service.media(plan['id'], item['id'])
        original.write_bytes(b'wrong')
        with patch.object(self.cloud, 'download') as download:
            with self.assertRaises(VaultError):
                self.service.media(plan['id'], item['id'], True)
            download.assert_not_called()
        self.assertEqual(list((self.service.root / 'view-cache').glob('*.thumbnail.png')), [])
        self.assertEqual(list((self.service.root / 'view-cache').glob('*.pending')), [])

    def test_uncommitted_or_wrong_item_is_not_accessible(self):
        plan = self.scan()
        with self.assertRaises(VaultError):
            self.service.media(plan['id'], plan['items'][0]['id'])
        saved = self.make_saved()
        with self.assertRaises(VaultError):
            self.service.media(saved['id'], 'unknown')

    def test_corrupt_download_is_not_served(self):
        plan = self.make_saved()
        image = next(i for i in plan['items'] if i['name'] == 'image.png')
        (self.source / 'Trip' / 'image.png').unlink()
        self.cloud.download = lambda key, version, target: target.write_bytes(b'wrong')
        with self.assertRaises(VaultError):
            self.service.media(plan['id'], image['id'])
        self.assertEqual(list((self.service.root / 'view-cache').glob('*.original')), [])
        self.assertEqual(list((self.service.root / 'view-cache').glob('*.pending')), [])

    def test_saved_library_api_media_range_and_boundary(self):
        app = create_app(self.root / 'range-library')
        # The API closes over its own service, so create the saved job there.
        from PIL import Image
        Image.new('RGB', (12, 12), 'red').save(self.source / 'Trip' / 'image.png')
        service = app.state.folder_uploads
        service.client_factory = lambda *args: self.cloud
        client = TestClient(app)
        headers = {'host': '127.0.0.1:8765'}
        plan = client.post('/api/v1/folder-uploads/scan', json={'path': str(self.source), 'bucket': 'test-bucket', 'profile': 'test-profile', 'region': 'ap-northeast-1'}, headers=headers).json()
        service.upload(plan['id'])
        response = client.get('/api/v1/folder-library', headers=headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()), 1)
        image = next(i for i in plan['items'] if i['name'] == 'image.png')
        url = f'/api/v1/folder-library/{plan["id"]}/items/{image["id"]}/content'
        response = client.get(url, headers={**headers, 'range': 'bytes=0-9'})
        self.assertEqual(response.status_code, 206)
        self.assertEqual(len(response.content), 10)
        self.assertIn('no-store', response.headers['cache-control'])
        self.assertEqual(client.get(url, headers={'host': 'evil.invalid'}).status_code, 403)


if __name__ == '__main__':
    unittest.main()

class CloudOnlyAPITests(unittest.TestCase):
    def test_local_mutations_removed_in_cloud_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            app = create_app(Path(directory) / 'data', cloud_only=True)
            client = TestClient(app, base_url='http://127.0.0.1:8765')
            for path in ['/api/v1/imports', '/api/v1/sync-directory', '/api/v1/import-local-directory', '/api/v1/assets', '/api/v1/collections']:
                self.assertEqual(client.post(path, json={}).status_code, 410)
            self.assertEqual(client.get('/api/v1/folder-library').status_code, 200)
