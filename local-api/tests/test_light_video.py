import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.light_video import LightVideos
from vault.service import VaultError
from test_vault import validate_contract
from fastapi.testclient import TestClient
from vault.app import create_app
from vault.folder_upload import FolderUploads
from test_folder_upload import FakeCloud


class LightVideoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.mov'
        self.source.write_bytes(b'original')
        self.service = LightVideos(self.root / 'data')

    def tearDown(self):
        self.service.shutdown()
        self.temp.cleanup()

    def inspect(self, video=None):
        with patch('vault.light_video.probe', return_value=(30.0, video or {}, 60.0)):
            return self.service.inspect({'path': str(self.source)})

    def test_inspect_contract_dedup_no_conversion(self):
        with patch('vault.light_video.subprocess.Popen') as start:
            job = self.inspect()
            validate_contract(job, 'LightVideo')
            self.assertEqual(job['id'], self.inspect()['id'])
            self.assertEqual(job['state'], 'planned')
            self.assertTrue(job['warning'])
            self.assertNotIn('source', job)
            start.assert_not_called()
        self.assertEqual(self.source.read_bytes(), b'original')

    def test_hdr_and_changed_original_rejected(self):
        with self.assertRaises(VaultError):
            self.inspect({'color_transfer': 'smpte2084'})
        job = self.inspect()
        self.source.write_bytes(b'changed')
        with self.assertRaises(VaultError):
            self.service.start(job['id'])

    def test_restart_does_not_resume_and_content_is_private_to_job(self):
        job = self.inspect()
        internal = self.service.read(job['id']); internal['state'] = 'creating'; self.service.save(internal)
        with patch('vault.light_video.subprocess.Popen') as start:
            recovered = LightVideos(self.root / 'data')
            self.assertEqual(recovered.read(job['id'])['state'], 'interrupted')
            start.assert_not_called()
        with self.assertRaises(VaultError):
            recovered.content(job['id'])
        with self.assertRaises(VaultError):
            recovered.read('../source')

    def test_failed_conversion_cleans_only_own_output(self):
        job = self.inspect()
        with patch('vault.light_video.subprocess.Popen', side_effect=OSError('secret path')):
            self.service.start(job['id'])
            for _ in range(100):
                if not self.service.active: break
                time.sleep(.01)
        result = self.service.read(job['id'])
        self.assertEqual(result['state'], 'failed')
        self.assertNotIn('secret', result['error'])
        self.assertEqual(self.source.read_bytes(), b'original')

    def test_cloud_only_api_range_and_cancel(self):
        app = create_app(self.root / 'api', cloud_only=True)
        with TestClient(app, base_url='http://127.0.0.1') as client:
            with patch('vault.light_video.probe', return_value=(30.0, {}, 60.0)):
                response = client.post('/api/v1/light-videos/inspect', json={'path': str(self.source)})
            self.assertEqual(response.status_code, 200)
            job = response.json()
            service = app.state.light_videos
            internal = service.read(job['id']); internal['state'] = 'creating'; service.save(internal)
            with patch.object(service, 'process') as process:
                response = client.post('/api/v1/light-videos/' + job['id'] + '/cancel')
                self.assertEqual(response.json()['state'], 'cancelled')
                process.terminate.assert_called_once()
            internal.update(state='complete', outputBytes=8); service.save(internal)
            (service.root / job['id'] / 'light.mp4').write_bytes(b'12345678')
            response = client.get('/api/v1/light-videos/' + job['id'] + '/content', headers={'Range': 'bytes=0-3'})
            self.assertEqual(response.status_code, 206)
            self.assertEqual(response.content, b'1234')
            self.assertEqual(response.headers['cache-control'], 'private, no-store')

    def complete_job(self):
        job = self.inspect()
        internal = self.service.read(job['id'])
        internal.update(state='complete', outputBytes=8)
        self.service.save(internal)
        (self.service.root / job['id'] / 'light.mp4').write_bytes(b'12345678')
        return job

    def uploader(self):
        cloud = FakeCloud()
        uploads = FolderUploads(self.root / 'uploads', client_factory=lambda *_: cloud)
        original_folder = self.root / 'originals'; original_folder.mkdir()
        (original_folder / 'photo.jpg').write_bytes(b'original-photo')
        uploads.scan({'path': str(original_folder), 'bucket': 'test-private-bucket', 'profile': 'test', 'region': 'ap-northeast-1'})
        return uploads, cloud

    def test_light_upload_preparation_has_no_cloud_calls_and_requires_confirmation(self):
        job = self.complete_job()
        uploads, cloud = self.uploader()
        plan = self.service.prepare_upload(job['id'], uploads)
        validate_contract(plan, 'FolderUpload')
        self.assertEqual(plan['name'], 'source（軽量版）')
        self.assertEqual(plan['items'][0]['name'], 'source-軽量版.mp4')
        self.assertEqual(plan['byteSize'], 8)
        self.assertFalse(cloud.objects)
        self.assertEqual(self.service.prepare_upload(job['id'], uploads)['id'], plan['id'])
        with self.assertRaises(VaultError):
            uploads.start(plan['id'], {'confirmUpload': False})
        uploads.upload(plan['id'])  # Explicit test call to the worker, simulated S3 only.
        self.assertEqual(uploads.read(plan['id'])['state'], 'complete')
        manifest = next(json.loads(value) for key,value in cloud.objects.items() if '/catalogs/' in key)
        self.assertEqual(manifest['name'], 'source（軽量版）')
        self.assertEqual(len(manifest['items']), 1)
        self.assertEqual(self.source.read_bytes(), b'original')

    def test_no_destination_and_unexpected_media_rejected(self):
        job = self.complete_job()
        with self.assertRaises(VaultError):
            self.service.prepare_upload(job['id'], FolderUploads(self.root / 'empty'))
        uploads, cloud = self.uploader()
        (self.service.root / job['id'] / 'unexpected.mp4').write_bytes(b'extra')
        with self.assertRaises(VaultError):
            self.service.prepare_upload(job['id'], uploads)
        self.assertFalse(cloud.objects)
