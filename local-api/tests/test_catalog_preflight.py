from copy import deepcopy
from unittest.mock import patch
from test_folder_upload import FolderUploadTests
from vault.service import VaultError


class CatalogPreflightTests(FolderUploadTests):
    def test_large_catalog_rejected_before_cloud_or_thread(self):
        plan = self.scan()
        raw = self.service.read(plan['id'])
        raw['items'] = [deepcopy(raw['items'][0]) for _ in range(10000)]
        self.service.save(raw)
        with patch('vault.folder_upload.threading.Thread') as thread:
            with self.assertRaises(VaultError):
                self.service.start(plan['id'], {'confirmUpload': True})
            with self.assertRaises(VaultError):
                self.service.start_queue([plan['id']], {'confirmUpload': True})
            thread.assert_not_called()
        self.assertEqual(self.cloud.puts, [])
        self.assertEqual(self.service.read(plan['id'])['state'], 'planned')

    def test_utf8_and_thumbnail_reserve_and_sealed_shape(self):
        raw = self.service.read(self.scan()['id'])
        normal = self.service.check_catalog_capacity(raw)
        raw['items'][0]['name'] += '写真' * 100
        self.assertEqual(self.service.check_catalog_capacity(raw) - normal, 600)
        self.service.sealed_catalog = True
        for item in raw['items']:
            item.pop('objectKey')
        self.assertLess(self.service.check_catalog_capacity(raw), normal)

    def test_scan_rejects_before_plan_saved(self):
        with patch.object(self.service, 'check_catalog_capacity', side_effect=VaultError('too_large', 'test', 413)):
            with self.assertRaises(VaultError):
                self.scan()
        self.assertEqual(self.service.list(), [])
        self.assertEqual(self.cloud.puts, [])
