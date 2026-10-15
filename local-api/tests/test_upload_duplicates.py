"""Content deduplication with isolated S3 and real encrypted catalogs."""
import base64
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.folder_upload import FolderUploads
from vault.encrypted_upload import EncryptedUploads
from vault.cloud_trash import CloudTrash
from vault.service import VaultError
from test_folder_upload import FakeCloud, validate_contract
from test_encrypted_upload import KEY_ID, KEY


class DuplicateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / 'Photos'; self.source.mkdir()
        self.cloud = FakeCloud()
        self.normal = FolderUploads(self.root / 'data', lambda *args: self.cloud)
        self.sealed = EncryptedUploads(self.root / 'data', lambda *args: self.cloud)
        self.body = {'path': str(self.source), 'bucket': 'test-bucket', 'profile': 'test', 'region': 'ap-northeast-1'}
        (self.source / 'one.png').write_bytes(b'original-photo')

    def send(self, service=None, body=None, key_id=KEY_ID, key=KEY):
        service = service or self.normal
        plan = service.scan(body or self.body)
        if isinstance(service, EncryptedUploads):
            if not service.helper.is_file(): self.fail('Build MediaHubCrypto first')
            raw = service.uploads.read(plan['id']); raw['keyID'] = key_id; service.uploads.save(raw)
            service.upload(plan['id'], key_id, key); uploads = service.uploads
        else:
            service.upload(plan['id']); uploads = service
        raw = uploads.read(plan['id'])
        self.assertEqual(raw['state'], 'complete', raw['error'])
        validate_contract(uploads.public(raw), 'FolderUpload')
        return raw

    def renamed(self):
        other = self.root / 'Elsewhere'; other.mkdir()
        (other / 'renamed.jpg').write_bytes((self.source / 'one.png').read_bytes())
        return self.body | {'path': str(other)}

    def test_normal_renamed_moved_duplicates_use_cloud_without_local_history(self):
        first = self.send(); before = list(self.cloud.puts)
        fresh = FolderUploads(self.root / 'fresh-mac', lambda *args: self.cloud)
        second = self.send(fresh, self.renamed())
        self.assertEqual(second['duplicateCount'], 1); self.assertEqual(second['items'], [])
        self.assertTrue(second['noCatalog']); self.assertEqual(before, self.cloud.puts)
        self.assertEqual(fresh.library(), [])
        self.assertEqual(self.normal.library()[0]['id'], first['id'])
        CloudTrash(fresh).sync_library()  # No nonexistent catalog read after duplicate-only success.

    def test_duplicates_within_one_selection_and_different_same_size_content(self):
        (self.source / 'copy.jpg').write_bytes(b'original-photo')
        (self.source / 'different.png').write_bytes(b'different-data')
        plan = self.send()
        self.assertEqual(plan['duplicateCount'], 1); self.assertEqual(len(plan['items']), 2)
        self.assertEqual(len([k for k in self.cloud.puts if '/originals/' in k]), 2)
        self.assertTrue(all(p.is_file() for p in self.source.iterdir()))

    def test_repeat_and_mixed_new_files_preserve_saved_root_and_original_metadata(self):
        first = self.send(); before = list(self.cloud.puts)
        repeated = self.send(); self.assertTrue(repeated['noCatalog']); self.assertEqual(before, self.cloud.puts)
        (self.source / 'one.png').rename(self.source / 'renamed.png')
        (self.source / 'new.png').write_bytes(b'new-photo')
        mixed = self.send()
        self.assertEqual(mixed['duplicateCount'], 1)
        self.assertEqual({i['name'] for i in mixed['items']}, {'one.png', 'new.png'})
        self.assertEqual(self.normal.library()[0]['id'], mixed['id'])
        self.assertEqual(len([k for k in self.cloud.puts if '/originals/' in k]), 2)
        self.assertIn(first['items'][0]['objectKey'], self.cloud.objects)
        CloudTrash(self.normal).sync_library()

    def test_cloud_lookup_error_fails_before_any_media_write(self):
        plan = self.normal.scan(self.body)
        with patch.object(self.cloud, 'call', side_effect=VaultError('cloud_error', 'lookup failed', 502)):
            self.normal.upload(plan['id'])
        self.assertEqual(self.normal.read(plan['id'])['state'], 'failed')
        self.assertEqual(self.cloud.puts, [])
        self.normal.upload(plan['id']); self.assertEqual(self.normal.read(plan['id'])['state'], 'complete')

    def test_missing_remote_original_is_not_a_duplicate(self):
        first = self.send(); del self.cloud.objects[first['items'][0]['objectKey']]
        second = self.send(body=self.renamed())
        self.assertEqual(second['duplicateCount'], 0); self.assertEqual(len(second['items']), 1)

    def test_trash_blocks_duplicate_until_original_is_purged(self):
        first = self.send(); catalog_key = next(k for k in self.cloud.objects if '/catalogs/' in k)
        value = json.loads(self.cloud.objects[catalog_key]); import uuid
        value['trash'] = [{'id': str(uuid.uuid4()), 'name': 'trashed', 'state': 'trashed',
                           'itemIds': [first['items'][0]['id']], 'folderIds': []}]
        self.cloud.objects[catalog_key] = json.dumps(value).encode()
        moved = self.renamed(); self.assertEqual(self.send(body=moved)['duplicateCount'], 1)
        value['trash'][0]['state'] = 'purged'; self.cloud.objects[catalog_key] = json.dumps(value).encode()
        del self.cloud.objects[first['items'][0]['objectKey']]
        self.assertEqual(self.send(body=moved)['duplicateCount'], 0)

    def test_skipped_candidates_are_rechecked_on_resume_after_prior_original_removed(self):
        first = self.send(); moved = self.renamed()
        other = Path(moved['path']); (other / 'new.png').write_bytes(b'new-data')
        plan = self.normal.scan(moved); self.cloud.fail_catalog = True; self.normal.upload(plan['id'])
        raw = self.normal.read(plan['id']); self.assertEqual(raw['state'], 'failed'); self.assertEqual(raw['duplicateCount'], 1)
        del self.cloud.objects[first['items'][0]['objectKey']]; self.cloud.fail_catalog = False
        self.normal.upload(plan['id']); raw = self.normal.read(plan['id'])
        self.assertEqual(raw['state'], 'complete', raw['error']); self.assertEqual(raw['duplicateCount'], 0)
        self.assertEqual(len(raw['items']), 2)

    def test_encrypted_renamed_moved_uses_decrypted_cloud_catalog_and_no_new_writes(self):
        self.send(self.sealed); before = list(self.cloud.puts)
        fresh = EncryptedUploads(self.root / 'fresh-mac', lambda *args: self.cloud)
        second = self.send(fresh, self.renamed())
        self.assertEqual(second['duplicateCount'], 1); self.assertTrue(second['noCatalog'])
        self.assertEqual(before, self.cloud.puts); self.assertEqual(fresh.library(), [])
        self.assertEqual(list(fresh.uploads.root.glob('duplicate-read-*')), [])
        for k, data in self.cloud.objects.items():
            self.assertTrue(data.startswith(b'MHSEAL01')); self.assertNotIn(b'original-photo', data)
            self.assertNotIn(second['duplicateItems'][0]['sha256'], k)

    def test_encrypted_same_selection_and_mixed_new_content(self):
        (self.source / 'copy.jpg').write_bytes(b'original-photo')
        first = self.send(self.sealed); self.assertEqual(first['duplicateCount'], 1)
        (self.source / 'new.png').write_bytes(b'new-data')
        second = self.send(self.sealed)
        self.assertEqual(second['duplicateCount'], 2); self.assertEqual(len(second['items']), 1)
        self.assertEqual(len([k for k in self.cloud.puts if '/encrypted-objects/' in k]), 2)

    def test_normal_encrypted_and_different_keys_are_separate(self):
        self.send(); self.assertEqual(self.send(self.sealed)['duplicateCount'], 0)
        self.assertEqual(self.send(self.sealed, key_id='20000000-0000-4000-8000-000000000002', key=b'\x33' * 32)['duplicateCount'], 0)

    def test_invalid_encrypted_catalog_and_wrong_key_stop_before_new_writes(self):
        self.send(self.sealed); before = list(self.cloud.puts)
        for damage in (False, True):
            if damage:
                key = next(k for k in self.cloud.objects if '/encrypted-catalogs/' in k)
                data = bytearray(self.cloud.objects[key]); data[-1] ^= 1; self.cloud.objects[key] = bytes(data)
            plan = self.sealed.scan(self.body)
            self.sealed.upload(plan['id'], KEY_ID, KEY if damage else b'\x44' * 32)
            self.assertEqual(self.sealed.uploads.read(plan['id'])['state'], 'failed')
            self.assertEqual(before, self.cloud.puts)

    def test_paginated_catalog_lookup_checks_later_pages(self):
        self.send(); original = self.cloud.call
        def paged(operation, *args):
            if '--continuation-token' not in args:
                return {'Contents': [], 'NextContinuationToken': 'page-two'}
            return original(operation, *args)
        with patch.object(self.cloud, 'call', side_effect=paged):
            self.assertEqual(self.send(body=self.renamed())['duplicateCount'], 1)

    def test_invalid_plain_catalog_stops_before_media_writes(self):
        self.send(); before = list(self.cloud.puts)
        catalog_key = next(k for k in self.cloud.objects if '/catalogs/' in k)
        value = json.loads(self.cloud.objects[catalog_key]); value['items'][0]['objectKey'] = 'unrelated/private'
        self.cloud.objects[catalog_key] = json.dumps(value).encode()
        plan = self.normal.scan(self.renamed()); self.normal.upload(plan['id'])
        self.assertEqual(self.normal.read(plan['id'])['state'], 'failed'); self.assertEqual(before, self.cloud.puts)

    def test_queue_rechecks_after_earlier_folder_commits(self):
        import time
        one = self.normal.scan(self.body); two = self.normal.scan(self.renamed())
        self.normal.start_queue([one['id'], two['id']], {'confirmUpload': True})
        deadline = time.monotonic() + 5
        while self.normal.running and time.monotonic() < deadline: time.sleep(.01)
        self.assertFalse(self.normal.running)
        self.assertEqual(self.normal.read(two['id'])['duplicateCount'], 1)
        self.assertEqual(len([k for k in self.cloud.puts if '/originals/' in k]), 1)

    def test_old_snapshot_original_still_stored_is_also_a_duplicate(self):
        self.send(); moved = self.renamed()
        (self.source / 'one.png').write_bytes(b'replacement-photo')
        self.send()
        before = list(self.cloud.puts)
        self.assertEqual(self.send(body=moved)['duplicateCount'], 1)
        self.assertEqual(self.cloud.puts, before)

    def test_catalog_bytes_reused_but_head_and_current_original_rechecked(self):
        from vault.upload_duplicates import catalogs
        first = self.send()
        with patch.object(self.cloud, 'download', wraps=self.cloud.download) as download:
            self.assertEqual(self.send()['duplicateCount'], 1)
            first_count = download.call_count
            self.assertGreater(first_count, 0)
            self.assertEqual(self.send()['duplicateCount'], 1)
            self.assertEqual(download.call_count, first_count)
            del self.cloud.objects[first['items'][0]['objectKey']]
            self.assertEqual(self.send()['duplicateCount'], 0)

    def test_cache_is_scoped_and_changed_etag_invalidates_same_version(self):
        from vault.upload_duplicates import CatalogCache, catalogs
        self.send()
        cache = CatalogCache()
        with patch.object(self.cloud, 'download', wraps=self.cloud.download) as download:
            def read(scope):
                return list(catalogs(self.cloud, 'media-hub/catalogs/', self.normal.root, cache=cache, scope=scope))
            read(('bucket', 'profile', 'region', None)); self.assertEqual(download.call_count, 1)
            read(('bucket', 'profile', 'region', None)); self.assertEqual(download.call_count, 1)
            read(('other-bucket', 'profile', 'region', None)); self.assertEqual(download.call_count, 2)
            key = next(k for k in self.cloud.objects if '/catalogs/' in k)
            value = json.loads(self.cloud.objects[key]); value['name'] = 'Updated'
            self.cloud.objects[key] = json.dumps(value).encode()
            self.assertEqual(read(('bucket', 'profile', 'region', None))[0][0]['name'], 'Updated')
            self.assertEqual(download.call_count, 3)

    def test_cached_encrypted_bytes_still_require_correct_key(self):
        self.send(self.sealed)
        self.send(self.sealed)  # Populate the ciphertext cache using the correct key.
        before = list(self.cloud.puts)
        plan = self.sealed.scan(self.body)
        with patch.object(self.cloud, 'download', wraps=self.cloud.download) as download:
            self.sealed.upload(plan['id'], KEY_ID, b'\x44' * 32)
            self.assertEqual(download.call_count, 0)
        self.assertEqual(self.sealed.uploads.read(plan['id'])['state'], 'failed')
        self.assertEqual(before, self.cloud.puts)
        for raw in self.sealed.uploads.duplicate_catalog_cache.entries.values():
            self.assertTrue(raw.startswith(b'MHSEAL01'))
            self.assertNotIn(b'original-photo', raw)

    def test_duplicate_scan_byte_and_count_limits_stop_before_new_media(self):
        self.send()
        before = list(self.cloud.puts)
        for limit in ['MAX_SCAN_DOWNLOAD_BYTES', 'MAX_SCAN_CATALOGS']:
            plan = self.normal.scan(self.renamed() if not (self.root / 'Elsewhere').exists() else self.body)
            with patch('vault.upload_duplicates.' + limit, 0):
                self.normal.upload(plan['id'])
            value = self.normal.read(plan['id'])
            self.assertEqual(value['state'], 'failed')
            self.assertIn('重複確認', value['error'])
            self.assertEqual(self.cloud.puts, before)

    def test_catalog_cache_evicts_to_byte_limit(self):
        from vault.upload_duplicates import CatalogCache
        cache = CatalogCache(maximum_bytes=6)
        cache.put('first', b'123'); cache.put('second', b'456')
        self.assertEqual(cache.get('first'), b'123')
        cache.put('third', b'789')
        self.assertIsNone(cache.get('second'))
        self.assertLessEqual(cache.byte_size, 6)
        cache.put('third', b'1')
        self.assertEqual(cache.byte_size, 4)

    def test_byte_limit_accepts_exact_size_and_stops_before_download_above_limit(self):
        from vault.upload_duplicates import catalogs
        self.send()
        size = len(next(value for key, value in self.cloud.objects.items() if '/catalogs/' in key))
        with patch('vault.upload_duplicates.MAX_SCAN_DOWNLOAD_BYTES', size):
            self.assertEqual(len(list(catalogs(self.cloud, 'media-hub/catalogs/', self.normal.root))), 1)
        with patch('vault.upload_duplicates.MAX_SCAN_DOWNLOAD_BYTES', size - 1), patch.object(self.cloud, 'download') as download:
            with self.assertRaises(VaultError) as error:
                list(catalogs(self.cloud, 'media-hub/catalogs/', self.normal.root))
            self.assertEqual(error.exception.code, 'duplicate_check_limit')
            download.assert_not_called()

    def test_missing_etag_never_reuses_catalog_bytes(self):
        self.send()
        original_head = self.cloud.head
        def head_without_etag(key):
            value = original_head(key)
            if value and '/catalogs/' in key:
                value.pop('ETag', None)
            return value
        with patch.object(self.cloud, 'head', side_effect=head_without_etag), patch.object(self.cloud, 'download', wraps=self.cloud.download) as download:
            self.send(); first = download.call_count
            self.send(); self.assertEqual(download.call_count, first + 1)
