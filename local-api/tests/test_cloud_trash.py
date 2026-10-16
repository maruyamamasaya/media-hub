import json
from pathlib import Path
import sys
import unittest
import threading
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.cloud_trash import CloudTrash
from vault.folder_upload import S3CLI, FolderUploads
from vault.service import VaultError
import test_folder_upload
from test_folder_upload import FakeCloud
from test_vault import validate_contract
from fastapi.testclient import TestClient
from vault.app import create_app


class TrashCloud(FakeCloud):
    def __init__(self):
        super().__init__()
        self.deleted = []
        self.fail_delete = False
        self.shared = False

    def download(self, key, version, target):
        super().download(key, version, target)
        return {'ETag': self.head(key)['ETag']}

    def require_unreferenced(self, keys, own):
        if self.shared:
            raise VaultError('shared_media', 'shared', 409)

    def purge_versions(self, key):
        if self.fail_delete:
            raise VaultError('cloud_error', 'failed', 502)
        self.objects.pop(key, None)
        self.deleted.append(key)


class CloudTrashTests(unittest.TestCase):
    def setUp(self):
        # Reuse the isolated upload fixture, without inheriting its test methods.
        fixture = test_folder_upload.FolderUploadTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.source, self.root = fixture.source, fixture.root
        self.cloud = TrashCloud()
        self.uploads = FolderUploads(self.root / 'library', lambda *args: self.cloud)
        self.plan = self.uploads.scan({'path': str(self.source), 'bucket': 'test-bucket', 'profile': 'test-profile', 'region': 'ap-northeast-1'})
        self.uploads.upload(self.plan['id'])
        self.trash = CloudTrash(self.uploads)

    def mutate(self, action, **fields):
        return self.trash.mutate(self.plan['id'], dict(action=action, confirm=True, **fields))

    def test_sixteen_mib_catalog_load_save_and_normal_duplicate_scan(self):
        from catalog_limits import MAX_CATALOG_BYTES
        from vault.upload_duplicates import catalogs
        plan = self.uploads.read(self.plan['id'])
        key = f'media-hub/catalogs/{plan["rootId"]}/{plan["id"]}.json'
        value = json.loads(self.cloud.objects[key]); value['catalogCreatedAt'] = 1
        plan['catalogCreatedAt'] = 1
        base = len(json.dumps(value).encode())
        value['name'] += 'x' * (MAX_CATALOG_BYTES - base)
        self.cloud.objects[key] = json.dumps(value).encode()
        client, loaded_key, etag, loaded = self.trash.load(plan)
        self.assertEqual(len(self.cloud.objects[key]), MAX_CATALOG_BYTES)
        self.trash.save(client, loaded_key, etag, loaded, plan)
        self.assertEqual(len(self.cloud.objects[key]), MAX_CATALOG_BYTES)
        scanned = list(catalogs(self.cloud, 'media-hub/catalogs/', self.uploads.root))
        self.assertEqual(scanned[0][0]['id'], plan['id'])
        loaded['name'] += 'x'
        with self.assertRaises(VaultError): self.trash.save(client, key, etag, loaded, plan)
        self.cloud.objects[key] = json.dumps(loaded).encode()
        with self.assertRaises(VaultError): self.trash.load(plan)
        with self.assertRaises(VaultError): list(catalogs(self.cloud, 'media-hub/catalogs/', self.uploads.root))

    def test_library_cache_expires_and_mutation_invalidates(self):
        with patch.object(self.trash, 'load', wraps=self.trash.load) as load:
            with patch('vault.cloud_trash.time.monotonic', return_value=100):
                self.trash.sync_library()
                self.trash.sync_library()
                self.assertEqual(load.call_count, 1)
            with patch('vault.cloud_trash.time.monotonic', return_value=131):
                self.trash.sync_library()
                self.assertEqual(load.call_count, 2)
                self.mutate('trash', itemIds=[self.plan['items'][0]['id']], folderId=None)
                before = load.call_count
                self.trash.sync_library()
                self.assertEqual(load.call_count, before + 1)

    def test_failed_library_read_is_not_cached(self):
        with patch.object(self.trash, 'load', side_effect=VaultError('cloud_error', 'offline', 502)) as load:
            for _ in range(2):
                with self.assertRaises(VaultError):
                    self.trash.sync_library()
            self.assertEqual(load.call_count, 2)

    def test_library_fetches_three_catalogs_concurrently(self):
        barrier = threading.Barrier(3, timeout=5)
        plans = [{'id': str(index)} for index in range(6)]
        def fetch(plan):
            barrier.wait()
            return plan
        with patch.object(self.uploads, 'list', return_value=plans), \
             patch.object(self.uploads, 'read', side_effect=lambda key: {'id': key}), \
             patch.object(self.trash, 'sync_cached', side_effect=fetch) as sync:
            self.trash.sync_library()
        self.assertEqual(sync.call_count, 6)

    def item_trash(self):
        self.mutate('trash', itemIds=[self.plan['items'][0]['id']], folderId=None)
        return self.trash.entries('')[0]

    def test_trash_restore_preserves_cloud_and_sources_and_restart(self):
        before = dict(self.cloud.objects)
        entry = self.item_trash()
        validate_contract(entry, 'CloudTrashEntry')
        self.assertEqual(len(self.uploads.library()[0]['items']), 1)
        with self.assertRaises(VaultError):
            self.uploads.media(self.plan['id'], entry['itemIds'][0])
        self.assertEqual(self.cloud.deleted, [])
        for key, data in before.items():
            if '/catalogs/' not in key:
                self.assertEqual(self.cloud.objects[key], data)
        self.assertTrue((self.source / 'movie.MP4').is_file())
        reloaded = CloudTrash(FolderUploads(self.root / 'library', lambda *args: self.cloud))
        self.assertEqual(reloaded.entries('')[0]['id'], entry['id'])
        self.mutate('restore', entryId=entry['id'])
        self.assertEqual(len(self.uploads.library()[0]['items']), 2)
        self.assertEqual(self.trash.entries(''), [])

    def test_root_and_empty_folder_trash_and_restore(self):
        for folder in [next(f for f in self.plan['folders'] if f['name'] == 'Empty'), next(f for f in self.plan['folders'] if f['parentId'] is None)]:
            self.mutate('trash', itemIds=[], folderId=folder['id'])
            entry = self.trash.entries('')[0]
            if folder['parentId'] is None:
                self.assertEqual(self.uploads.library(), [])
            else:
                self.assertNotIn(folder['id'], [f['id'] for f in self.uploads.library()[0]['folders']])
            self.mutate('restore', entryId=entry['id'])
        self.assertEqual(len(self.uploads.library()[0]['folders']), 3)

    def test_failure_keeps_deleting_state_and_retry_is_idempotent(self):
        entry = self.item_trash()
        self.cloud.fail_delete = True
        with self.assertRaises(VaultError):
            self.mutate('purge', entryId=entry['id'])
        self.assertEqual(self.trash.entries('')[0]['state'], 'deleting')
        with self.assertRaises(VaultError):
            self.mutate('restore', entryId=entry['id'])
        self.cloud.fail_delete = False
        self.mutate('purge', entryId=entry['id'])
        self.assertEqual(self.trash.entries(''), [])
        self.assertEqual(len(self.uploads.library()[0]['items']), 1)
        self.mutate('purge', entryId=entry['id'])
        self.assertEqual(len(self.cloud.deleted), 1)
        self.assertTrue((self.source / 'movie.MP4').exists())

    def test_shared_media_and_catalog_failure_never_delete(self):
        entry = self.item_trash()
        self.cloud.shared = True
        with self.assertRaises(VaultError):
            self.mutate('purge', entryId=entry['id'])
        self.assertEqual(self.trash.entries('')[0]['state'], 'trashed')
        self.cloud.shared = False
        self.cloud.fail_catalog = True
        with self.assertRaises(VaultError):
            self.mutate('purge', entryId=entry['id'])
        self.assertEqual(self.cloud.deleted, [])

    def test_invalid_confirmation_selection_and_overlap_rejected(self):
        with self.assertRaises(VaultError):
            self.trash.mutate(self.plan['id'], {'action': 'trash', 'confirm': False, 'itemIds': [], 'folderId': None})
        with self.assertRaises(VaultError):
            self.mutate('trash', itemIds=['invalid'], folderId=None)
        self.item_trash()
        root = next(f for f in self.plan['folders'] if f['parentId'] is None)
        with self.assertRaises(VaultError):
            self.mutate('trash', itemIds=[], folderId=root['id'])
        self.assertEqual(self.cloud.deleted, [])

    def test_endpoint_and_cloud_only_boundary(self):
        app = create_app(self.root / 'library', cloud_only=True)
        app.state.folder_uploads.client_factory = lambda *args: self.cloud
        client = TestClient(app)
        path = f'/api/v1/folder-library/{self.plan["id"]}/trash'
        body = dict(action='trash', confirm=True, itemIds=[self.plan['items'][0]['id']], folderId=None)
        self.assertEqual(client.post(path, json=body, headers={'host': 'evil.invalid'}).status_code, 403)
        self.assertEqual(client.post(path, json=body, headers={'host': '127.0.0.1:8765'}).status_code, 200)
        self.assertEqual(len(client.get('/api/v1/folder-library/trash', headers={'host': '127.0.0.1:8765'}).json()), 1)

    def test_cli_exact_key_pagination_versions_and_markers(self):
        cli = S3CLI('bucket', 'profile', 'region')
        pages = [dict(Versions=[{'Key': 'target', 'VersionId': 'old'}, {'Key': 'target-other', 'VersionId': 'keep'}], IsTruncated=True, NextKeyMarker='target', NextVersionIdMarker='old'), dict(DeleteMarkers=[{'Key': 'target', 'VersionId': 'marker'}]), {}, {}, {}]
        with patch.object(cli, 'call', side_effect=pages) as call:
            cli.purge_versions('target')
        deletes = [args.args for args in call.call_args_list if args.args[0] == 'delete-object']
        self.assertEqual(deletes, [('delete-object', '--key', 'target', '--version-id', 'old'), ('delete-object', '--key', 'target', '--version-id', 'marker')])

    def test_cli_reference_guard_checks_other_catalogs(self):
        cli = S3CLI('bucket', 'profile', 'region')
        with patch.object(cli, 'call', return_value={'Contents': [{'Key': 'other', 'Size': 50}]}), patch.object(cli, 'download', side_effect=lambda k, v, p: p.write_text(json.dumps({'items': [{'objectKey': 'target'}]}))):
            with self.assertRaises(VaultError) as error:
                cli.require_unreferenced({'target'}, 'own')
        self.assertEqual(error.exception.code, 'shared_media')

    def test_bulk_trash_and_thumbnail_purge_preserve_unselected_objects(self):
        raw = self.uploads.read(self.plan['id'])
        selected = raw['items'][0]
        thumbnail = f'media-hub/thumbnails/{selected["id"]}/{selected["sha256"]}.png'
        selected['thumbnailKey'] = thumbnail
        self.uploads.save(raw)
        key = f'media-hub/catalogs/{raw["rootId"]}/{raw["id"]}.json'
        value = json.loads(self.cloud.objects[key])
        value['items'][0]['thumbnailKey'] = thumbnail
        self.cloud.objects[key] = json.dumps(value).encode()
        self.cloud.objects[thumbnail] = b'preview'
        other = raw['items'][1]['objectKey']
        entry = self.item_trash()
        self.mutate('purge', entryId=entry['id'])
        self.assertEqual(set(self.cloud.deleted), {selected['objectKey'], thumbnail})
        self.assertIn(other, self.cloud.objects)
        self.mutate('trash', itemIds=[raw['items'][1]['id']], folderId=None)
        self.assertEqual(self.uploads.library()[0]['items'], [])

    def test_locked_trash_hidden_and_mutations_require_unlock(self):
        from vault.folder_privacy import security
        entry = self.item_trash()
        raw = self.uploads.read(self.plan['id'])
        folder = next(f for f in raw['folders'] if f['parentId'] is None)
        settings = security.empty_settings()
        settings['locks'] = [security.make_lock(raw['rootId'], folder['id'], '012345')]
        self.cloud.objects[security.KEY] = json.dumps(settings).encode()
        app = create_app(self.root / 'library', cloud_only=True, privacy_enabled=True)
        app.state.folder_uploads.client_factory = lambda *args: self.cloud
        with TestClient(app, base_url='http://127.0.0.1') as client:
            self.assertEqual(client.get('/api/v1/folder-library/trash').json(), [])
            path = f'/api/v1/folder-library/{self.plan["id"]}/trash'
            body = dict(action='restore', confirm=True, entryId=entry['id'])
            self.assertEqual(client.post(path, json=body).status_code, 403)
            self.assertEqual(client.post('/api/v1/folder-locks/unlock', json={'password': '012345'}).status_code, 200)
            self.assertEqual(len(client.get('/api/v1/folder-library/trash').json()), 1)
            self.assertEqual(client.post(path, json=body).status_code, 200)

    def test_conditional_conflict_never_starts_physical_deletion(self):
        entry = self.item_trash()
        def conflict(*args, **kwargs):
            raise VaultError('conflict', 'etag mismatch', 409)
        with patch.object(self.cloud, 'put', side_effect=conflict):
            with self.assertRaises(VaultError):
                self.mutate('purge', entryId=entry['id'])
        self.assertEqual(self.cloud.deleted, [])
        self.assertEqual(self.trash.entries('')[0]['state'], 'trashed')

    def test_bulk_selection_is_one_restorable_entry(self):
        ids = [i['id'] for i in self.plan['items']]
        self.mutate('trash', itemIds=ids, folderId=None)
        entry = self.trash.entries('')[0]
        self.assertEqual(set(entry['itemIds']), set(ids))
        self.assertEqual(self.uploads.library()[0]['items'], [])
        self.mutate('restore', entryId=entry['id'])
        self.assertEqual(len(self.uploads.library()[0]['items']), 2)
