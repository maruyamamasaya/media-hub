import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.thumbnail_cache import ThumbnailCache
from vault.app import create_app
from vault.service import VaultError
import test_folder_upload as fixtures


class ThumbnailCacheTests(unittest.TestCase):
    def test_eviction_integrity_and_clear_prevent_inflight_repopulation(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = ThumbnailCache(temp, limit=6)
            digest = lambda data: hashlib.sha256(data).hexdigest()
            cache.store('one', b'1234', digest(b'1234'), 0)
            cache.store('two', b'5678', digest(b'5678'), 0)
            self.assertIsNone(cache.read('one', digest(b'1234')))
            self.assertEqual(cache.read('two', digest(b'5678')), b'5678')
            self.assertLessEqual(cache.stats()['bytes'], 6)
            cache.path('two').write_bytes(b'bad')
            self.assertIsNone(cache.read('two', digest(b'5678')))
            cache.clear()
            cache.store('late-response', b'1234', digest(b'1234'), 0)
            self.assertEqual(cache.stats()['bytes'], 0)


class CachedMediaTests(unittest.TestCase):
    setUp = fixtures.FolderUploadTests.setUp
    scan = fixtures.FolderUploadTests.scan
    make_saved = fixtures.CloudLibraryTests.make_saved

    def test_cache_clear_redownload_and_trashed_media_rejection(self):
        plan = self.make_saved()
        item = next(i for i in plan['items'] if i['name'] == 'image.png')
        with patch.object(self.cloud, 'download', wraps=self.cloud.download) as download:
            for _ in range(2):
                file, _, _ = self.service.media(plan['id'], item['id'], True)
                self.service.release_media(file)
            self.assertEqual(download.call_count, 1)
            self.service.thumbnail_cache.clear()
            file, _, _ = self.service.media(plan['id'], item['id'], True)
            self.service.release_media(file)
            self.assertEqual(download.call_count, 2)
        plan['trash'] = [{'itemIds': [item['id']]}]
        self.service.save(plan)
        with self.assertRaises(VaultError): self.service.media(plan['id'], item['id'], True)
        self.assertTrue((self.source / 'Trip' / 'image.png').exists())

    def test_pin_authorization_runs_before_cached_content_on_every_request(self):
        plan = self.make_saved()
        item = next(i for i in plan['items'] if i['name'] == 'image.png')
        app = create_app(self.root / 'app', privacy_enabled=True)
        app.state.folder_uploads.media = self.service.media
        # Inspect the route's privacy object via a shared class mock; never bypass it.
        with patch('vault.folder_privacy.FolderPrivacy.authorize') as authorize:
            with TestClient(app, base_url="http://127.0.0.1") as client:
                url = f"/api/v1/folder-library/{plan['id']}/items/{item['id']}/content?thumbnail=true"
                self.assertEqual(client.get(url).status_code, 200)
                authorize.side_effect = VaultError('not_found', 'locked', 404)
                self.assertEqual(client.get(url).status_code, 404)
                self.assertEqual(authorize.call_count, 2)
