import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_folder_upload as fixtures
from vault.shared_favorites import execute, FavoriteS3Bridge
from vault.folder_upload import S3CLI
from vault.service import VaultError
import favorites
import folder_security
import reader


class SharedFavoriteBridgeTests(unittest.TestCase):
    setUp = fixtures.FolderUploadTests.setUp
    scan = fixtures.FolderUploadTests.scan
    make_saved = fixtures.CloudLibraryTests.make_saved

    def test_desktop_write_phone_read_phone_remove_desktop_read_same_storage(self):
        plan = self.make_saved()
        self.cloud.objects[folder_security.KEY] = json.dumps(folder_security.empty_settings()).encode()
        target = plan['items'][0]
        ref = dict(space='normal', rootId=plan['rootId'], catalogId=plan['id'], targetId=target['id'], kind='item')
        destination = {k: plan[k] for k in ('bucket', 'profile', 'region')}
        self.assertEqual(execute(self.service, destination | {'reference': ref, 'favorite': True}, '', write=True), {'saved': True})
        bridge = FavoriteS3Bridge(self.cloud, self.service.root)
        settings = folder_security.load(bridge, plan['bucket'])
        authorize = lambda value: favorites.visible(bridge, plan['bucket'], value, settings, set(), reader.catalog, {})
        self.assertEqual(favorites.listing(bridge, plan['bucket'], authorize), [ref])
        self.assertEqual(favorites.update(bridge, plan['bucket'], {'reference': ref, 'favorite': False}, authorize)[0], 200)
        self.assertEqual(execute(self.service, destination, ''), [])
        self.assertTrue((self.source / target['relativePath']).exists())

    def test_cli_conditional_write_failure_is_retryable_conflict(self):
        class Failure:
            returncode = 1
            stderr = 'An error occurred (PreconditionFailed)'
            stdout = ''
        with patch('vault.folder_upload.subprocess.run', return_value=Failure()):
            with self.assertRaises(VaultError) as error:
                S3CLI('test-bucket', 'test', 'ap-northeast-1').call('put-object')
            self.assertEqual(error.exception.code, 'conflict')
