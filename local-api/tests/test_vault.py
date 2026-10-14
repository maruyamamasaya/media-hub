import io
import hashlib
import zipfile
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'local-api'))
from vault.app import create_app
from vault.service import Vault, VaultError
from vault.storage import checksum


def image_bytes(color='orange', fmt='PNG'):
    stream = io.BytesIO()
    Image.new('RGB', (40, 30), color).save(stream, fmt)
    return stream.getvalue()


def validate_contract(value, definition):
    schema = json.loads((ROOT / 'contracts/asset.schema.json').read_text(encoding='utf-8'))
    def validate(v, model):
        if '$ref' in model:
            return validate(v, schema['$defs'][model['$ref'].split('/')[-1]])
        kind = model['type']
        if isinstance(kind, list):
            if v is None and 'null' in kind:
                return
            kind = next(k for k in kind if k != 'null')
        mapping = {'string': str, 'integer': int, 'boolean': bool, 'object': dict, 'array': list}
        assert (type(v) in (int, float) if kind == 'number' else type(v) is mapping[kind]), (v, kind)
        if kind == 'object':
            assert set(model['required']) <= set(v)
            assert set(v) <= set(model['properties'])
            for key in v:
                validate(v[key], model['properties'][key])
        elif kind == 'array':
            for entry in v:
                validate(entry, model['items'])
    validate(value, schema['$defs'][definition])


class VaultTests(unittest.TestCase):
    def setUp(self):
        test_root = ROOT / '.local/test-runs'
        test_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=test_root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = create_app(self.root / 'data', self.root / 'fixtures')
        self.client = TestClient(self.app, base_url='http://127.0.0.1:8765')
        self.addCleanup(self.client.close)
        self.vault = self.app.state.vault

    def upload(self, contents=None, filename='study.png'):
        response = self.client.post('/api/v1/imports', files={'files': (filename, contents or image_bytes(), 'image/png')})
        self.assertEqual(response.status_code, 200, response.text)
        job = response.json()
        validate_contract(job, 'ImportJob')
        return job

    def asset(self):
        job = self.upload()
        return self.client.get('/api/v1/assets/' + job['items'][0]['assetId']).json()

    def test_folder_sync_reference_rename_relocate_changed_and_missing(self):
        folder = self.root / 'finder images'
        folder.mkdir()
        path = folder / 'sample.png'
        raw = image_bytes('navy')
        path.write_bytes(raw)
        first = self.vault.sync_directory({'path': str(folder), 'rootId': None})
        self.assertEqual(first['added'], 1)
        validate_contract(first, 'SyncDirectoryResult')
        asset = self.vault.list_assets()['items'][0]
        self.assertEqual(asset['originalOwnership'], 'reference')
        old_id = asset['id']
        path.rename(folder / 'renamed.png')
        result = self.vault.sync_directory({'path': str(folder), 'rootId': first['rootId']})
        self.assertEqual(result['moved'], 1)
        self.assertEqual(result['missing'], 0)
        self.assertEqual(self.vault.list_assets()['items'][0]['id'], old_id)
        moved = self.root / 'moved folder'
        folder.rename(moved)
        self.assertEqual(self.vault.storage_roots()[0]['state'], 'missing')
        response = self.client.post('/api/v1/sync-directory', json={'path': str(folder), 'rootId': first['rootId']})
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.json()['code'], 'folder_missing')
        restored = self.vault.sync_directory({'path': str(moved), 'rootId': first['rootId']})
        self.assertEqual(restored['rootId'], first['rootId'])
        original = next(f for f in self.vault.asset(old_id)['files'] if f['role'] == 'original')
        self.assertEqual(original['state'], 'ready')
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertEqual(next(f for f in restarted.asset(old_id)['files'] if f['role'] == 'original')['state'], 'ready')
        source = moved / 'renamed.png'
        source.write_bytes(image_bytes('lime'))
        changed = restarted.sync_directory({'path': str(moved), 'rootId': first['rootId']})
        self.assertEqual(changed['changed'], 1)
        self.assertEqual(restarted.list_assets()['total'], 1)
        source.unlink()
        missing = restarted.sync_directory({'path': str(moved), 'rootId': first['rootId']})
        self.assertEqual(missing['missing'], 1)
        source.write_bytes(raw)
        current = restarted.asset(old_id)
        uploaded = restarted.transfer_original(old_id, {'revision': current['revision'], 'destination': 'development-remote', 'removeLocal': True})
        self.assertFalse(source.exists())
        self.assertFalse(uploaded['localCleanupPending'])
        self.assertEqual(restarted.sync_directory({'path': str(moved), 'rootId': first['rootId']})['missing'], 0)

    def test_folder_sync_matches_existing_remote_and_protects_symlink(self):
        existing = self.asset()
        existing = self.vault.transfer_original(existing['id'], {'revision': existing['revision'], 'destination': 'development-remote', 'removeLocal': True})
        folder = self.root / 'chosen folder'
        folder.mkdir()
        source = folder / 'same-content.png'
        source.write_bytes(image_bytes())
        synced = self.vault.sync_directory({'path': str(folder), 'rootId': None})
        self.assertEqual(synced['matched'], 1)
        self.assertEqual(self.vault.list_assets()['total'], 1)
        asset = self.vault.asset(existing['id'])
        self.assertEqual(asset['storageLocation'], 'local')
        self.assertTrue(asset['remoteAvailable'])
        validate_contract(self.vault.storage_roots()[0], 'StorageRoot')
        response = self.client.post('/api/v1/sync-directory', json={'path': str(self.vault.root), 'rootId': None})
        self.assertEqual(response.status_code, 400)
        outsider = self.root / 'outside.png'
        outsider.write_bytes(image_bytes('purple'))
        try:
            (folder / 'link.png').symlink_to(outsider)
        except OSError:
            return  # Windows without symlink permission; containment still enforced by storage.path.
        self.vault.sync_directory({'path': str(folder), 'rootId': synced['rootId']})
        self.assertEqual(self.vault.list_assets()['total'], 1)

    def test_transfer_roundtrip_preserves_original_and_archive(self):
        asset = self.asset()
        original = next(f for f in asset['files'] if f['role'] == 'original')
        source = self.vault.storage.path(original['objectKey'])
        uploaded = self.vault.transfer_original(asset['id'], {'revision': asset['revision'], 'destination': 'development-remote', 'removeLocal': True})
        uploaded = self.vault.archive_asset(uploaded['id'], {'revision': uploaded['revision'], 'archived': True})
        self.assertFalse(source.exists())
        self.assertTrue(uploaded['remoteAvailable'])
        self.assertFalse(uploaded['localCleanupPending'])
        remote_file = next(f for f in uploaded['files'] if f['role'] == 'original')
        remote_path = self.vault.storage.path(remote_file['objectKey'])
        self.assertEqual(checksum(remote_path), original['sha256'])
        downloaded = self.vault.transfer_original(asset['id'], {'revision': uploaded['revision'], 'destination': 'local', 'removeLocal': False})
        self.assertTrue(remote_path.exists())
        self.assertIsNone(downloaded['archivedAt'])
        self.assertTrue(downloaded['remoteAvailable'])
        self.assertEqual(downloaded['storageLocation'], 'local')
        validate_contract(downloaded, 'Asset')
        repeated = self.vault.transfer_original(asset['id'], {'revision': downloaded['revision'], 'destination': 'local', 'removeLocal': False})
        self.assertEqual(repeated['revision'], downloaded['revision'])
        self.assertEqual(self.client.post('/api/v1/assets/'+asset['id']+'/transfer', json={'revision': asset['revision'], 'destination': 'local', 'removeLocal': False}).status_code, 409)
        uploaded_again = self.vault.transfer_original(asset['id'], {'revision': downloaded['revision'], 'destination': 'development-remote', 'removeLocal': True})
        self.assertEqual(next(f for f in uploaded_again['files'] if f['role'] == 'original')['objectKey'], remote_file['objectKey'])

    def test_transfer_failure_retains_source_and_cleanup_retry_after_restart(self):
        asset = self.asset()
        original = next(f for f in asset['files'] if f['role'] == 'original')
        source = self.vault.storage.path(original['objectKey'])
        body = {'revision': asset['revision'], 'destination': 'development-remote', 'removeLocal': True}
        with patch.object(self.vault.storage, 'put', side_effect=OSError('full')):
            with self.assertRaises(OSError): self.vault.transfer_original(asset['id'], body)
        self.assertTrue(source.exists())
        self.assertEqual(self.vault.asset(asset['id'])['storageLocation'], 'local')
        with patch.object(self.vault, 'complete_transfer_cleanup', side_effect=OSError('busy')):
            uploaded = self.vault.transfer_original(asset['id'], body)
        self.assertTrue(uploaded['localCleanupPending'])
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertTrue(source.exists())
        source.write_bytes(image_bytes('pink'))
        with self.assertRaises(VaultError): restarted.transfer_original(asset['id'], {'revision': uploaded['revision'], 'destination': 'development-remote', 'removeLocal': True})
        self.assertTrue(source.exists())
        source.write_bytes(image_bytes())
        retried = restarted.transfer_original(asset['id'], {'revision': uploaded['revision'], 'destination': 'development-remote', 'removeLocal': True})
        self.assertFalse(retried['localCleanupPending'])
        self.assertFalse(source.exists())

    def test_transfer_reference_only_deletes_explicit_source_and_rejects_trash(self):
        path = self.vault.local_directory / 'reference.png'
        path.write_bytes(image_bytes('teal'))
        job = self.vault.local_import()
        asset = self.vault.asset(job['items'][0]['assetId'])
        body = {'revision': asset['revision'], 'destination': 'development-remote', 'removeLocal': False}
        self.assertEqual(self.client.post('/api/v1/assets/'+asset['id']+'/transfer', json=body).status_code, 400)
        self.assertTrue(path.exists())
        body['removeLocal'] = True
        uploaded = self.vault.transfer_original(asset['id'], body)
        self.assertFalse(path.exists())
        trashed = self.vault.trash(asset['id'], uploaded['revision'])
        body.update(revision=trashed['revision'], destination='local', removeLocal=False)
        self.assertEqual(self.client.post('/api/v1/assets/'+asset['id']+'/transfer', json=body).status_code, 400)

    def test_existing_original_migrates_to_development_remote_once(self):
        asset = self.asset()
        original = next(f for f in asset['files'] if f['role'] == 'original')
        before = checksum(self.vault.storage.path(original['objectKey']))
        with self.vault.repo.connect() as db:
            db.execute('DROP INDEX asset_location')
            for column in ('storageLocation', 'originalOwnership', 'originalModifiedNs'):
                db.execute(f'ALTER TABLE assets DROP COLUMN {column}')
            db.execute('PRAGMA user_version=3')
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertEqual(restarted.asset(asset['id'])['storageLocation'], 'development-remote')
        self.assertEqual(checksum(restarted.storage.path(original['objectKey'])), before)
        job = restarted.new_job()
        restarted.add_stream(job, 'new.png', io.BytesIO(image_bytes('green')))
        local_id = restarted.job(job)['items'][0]['assetId']
        again = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertEqual(again.asset(local_id)['storageLocation'], 'local')
        self.assertEqual(again.list_assets(location='local')['total'], 1)
        self.assertEqual(again.list_assets(location='development-remote')['total'], 1)
        validate_contract(again.asset(local_id), 'Asset')

    def test_local_directory_reference_missing_changed_and_delete_preserves_source(self):
        path = self.vault.local_directory / 'folder' / 'local sample.png'
        path.parent.mkdir()
        raw = image_bytes('purple')
        path.write_bytes(raw)
        result = self.client.post('/api/v1/import-local-directory').json()
        self.assertEqual(result['items'][0]['state'], 'ready')
        asset_id = result['items'][0]['assetId']
        asset = self.vault.asset(asset_id)
        self.assertEqual(asset['storageLocation'], 'local')
        self.assertEqual(asset['originalOwnership'], 'reference')
        original = next(f for f in asset['files'] if f['role'] == 'original')
        self.assertEqual(self.vault.storage.path(original['objectKey']), path)
        self.assertEqual(self.vault.local_import()['items'], [])
        path.write_bytes(image_bytes('black'))
        self.assertEqual(next(f for f in self.vault.asset(asset_id)['files'] if f['role'] == 'original')['state'], 'changed')
        self.assertEqual(self.client.get(f"/api/v1/assets/{asset_id}/files/{original['id']}/content").status_code, 404)
        self.assertEqual(self.client.post('/api/v1/bulk-download', json={'assets': [{'id': asset_id, 'revision': asset['revision']}]}).status_code, 409)
        path.unlink()
        self.assertEqual(next(f for f in self.vault.asset(asset_id)['files'] if f['role'] == 'original')['state'], 'missing')
        path.write_bytes(raw)
        self.assertEqual(next(f for f in self.vault.asset(asset_id)['files'] if f['role'] == 'original')['state'], 'ready')
        trashed = self.vault.trash(asset_id, asset['revision'])
        self.vault.delete(asset_id, trashed['revision'])
        self.assertEqual(path.read_bytes(), raw)

    def test_location_filter_cursor_and_archive_independent(self):
        first = self.asset()
        self.upload(image_bytes('blue'))
        page = self.vault.list_assets(limit=1)
        self.assertEqual(self.client.get('/api/v1/assets', params={'cursor': page['nextCursor'], 'location': 'local'}).status_code, 400)
        self.assertEqual(self.client.post(f'/api/v1/assets/{first["id"]}/archive', json={'revision': first['revision'], 'archived': True}).status_code, 400)
        first = self.vault.transfer_original(first['id'], {'revision': first['revision'], 'destination': 'development-remote', 'removeLocal': True})
        archived = self.vault.archive_asset(first['id'], {'revision': first['revision'], 'archived': True})
        self.assertEqual(archived['storageLocation'], 'development-remote')
        self.assertEqual(self.vault.list_assets(view='archive', location='local')['total'], 0)
        self.assertEqual(self.client.get('/api/v1/assets?location=invalid').status_code, 400)

    def test_bulk_organize_atomic_conflict_and_zip_originals(self):
        raw = [image_bytes('red'), image_bytes('blue')]
        ids = [self.upload(data, 'same.png')['items'][0]['assetId'] for data in raw]
        selection = [{'id': asset_id, 'revision': self.vault.asset(asset_id)['revision']} for asset_id in ids]
        tag = self.vault.create_entity('tags', 'bulk')
        body = {'assets': selection, 'entity': 'tags', 'itemIds': [tag['id']], 'mode': 'add'}
        self.assertEqual(self.client.post('/api/v1/bulk-organize', json=body).json(), {'updated': 2})
        self.assertTrue(all(self.vault.asset(i)['tags'][0]['id'] == tag['id'] for i in ids))
        # Stale revisions must not partially clear either asset.
        body.update(mode='replace', itemIds=[])
        self.assertEqual(self.client.post('/api/v1/bulk-organize', json=body).status_code, 409)
        self.assertTrue(all(self.vault.asset(i)['tags'] for i in ids))
        selection = [{'id': i, 'revision': self.vault.asset(i)['revision']} for i in ids]
        collection = self.vault.create_entity('collections', 'batch')
        body.update(assets=selection, entity='collections', itemIds=[collection['id']])
        self.assertEqual(self.client.post('/api/v1/bulk-organize', json=body).status_code, 200)
        selection = [{'id': i, 'revision': self.vault.asset(i)['revision']} for i in ids]
        response = self.client.post('/api/v1/bulk-download', json={'assets': selection})
        self.assertEqual(response.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
            self.assertEqual(archive.namelist(), ['001_same.png', '002_same.png'])
            self.assertEqual([archive.read(n) for n in archive.namelist()], raw)
        self.assertEqual(self.client.post('/api/v1/bulk-download', json={'assets': selection + selection}).status_code, 400)
        body.update(assets=selection, entity='tags', itemIds=[], mode='replace')
        self.assertEqual(self.client.post('/api/v1/bulk-organize', json=body).status_code, 200)
        self.assertTrue(all(not self.vault.asset(i)['tags'] for i in ids))

    def test_metadata_filters_sorts_and_cursor(self):
        ids = [self.upload(image_bytes(color), name)['items'][0]['assetId'] for color, name in [('red', 'A.PNG'), ('blue', 'b.jpg'), ('green', 'c.webp')]]
        first = self.vault.create_entity('tags', 'first')
        second = self.vault.create_entity('tags', 'second')
        for asset_id, tag_ids in zip(ids, [[first['id'], second['id']], [first['id']], []]):
            asset = self.vault.asset(asset_id)
            self.vault.update(asset_id, {'revision': asset['revision'], 'tagIds': tag_ids})
        both = self.client.get('/api/v1/assets', params=[('tag', first['id']), ('tag', second['id']), ('extension', '.PNG')]).json()
        self.assertEqual([a['id'] for a in both['items']], [ids[0]])
        either = self.client.get('/api/v1/assets', params=[('extension', 'jpg'), ('extension', 'webp')]).json()
        self.assertEqual(either['total'], 2)
        with self.vault.repo.connect() as db:
            for i, asset_id in enumerate(ids):
                date = f'2026-10-0{i+1}T00:00:00Z'
                db.execute('UPDATE assets SET createdAt=?,updatedAt=?,capturedAt=? WHERE id=?', (date, date, date, asset_id))
                db.execute("UPDATE files SET byteSize=? WHERE assetId=? AND role='original'", (100 + i, asset_id))
        for sort in ['added', 'updated', 'captured', 'name', 'size']:
            for order, expected in [('asc', ids), ('desc', list(reversed(ids)))]:
                result_ids, cursor = [], None
                while True:
                    page = self.vault.list_assets(sort=sort, order=order, limit=1, cursor=cursor)
                    result_ids.extend(a['id'] for a in page['items'])
                    cursor = page['nextCursor']
                    if not cursor:
                        break
                self.assertEqual(result_ids, expected, (sort, order))
        cursor = self.vault.list_assets(limit=1)['nextCursor']
        self.assertEqual(self.client.get('/api/v1/assets', params={'cursor': cursor, 'extension': 'png'}).status_code, 400)
        self.assertEqual(self.client.get('/api/v1/assets?order=invalid').status_code, 400)

    def test_v1_extension_migration_preserves_asset_contract(self):
        asset = self.asset()
        with self.vault.repo.connect() as db:
            db.execute('DROP INDEX asset_extension')
            db.execute('ALTER TABLE assets DROP COLUMN originalExtension')
            db.execute('PRAGMA user_version=1')
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertEqual(restarted.list_assets(extensions=['PNG'])['total'], 1)
        validate_contract(restarted.asset(asset['id']), 'Asset')
        with restarted.repo.connect() as db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 7)

    def test_archive_preserves_metadata_files_restart_and_trash_restore(self):
        asset = self.asset()
        asset = self.vault.transfer_original(asset['id'], {'revision': asset['revision'], 'destination': 'development-remote', 'removeLocal': True})
        tag = self.vault.create_entity('tags', 'keep')
        collections = [self.vault.create_entity('collections', name) for name in ['first', 'second']]
        asset = self.vault.update(asset['id'], {'revision': asset['revision'], 'name': 'archived study', 'note': 'keep note', 'favorite': True, 'tagIds': [tag['id']], 'collectionIds': [c['id'] for c in collections]})
        size = self.vault.status()['byteSize']
        response = self.client.post(f'/api/v1/assets/{asset["id"]}/archive', json={'revision': asset['revision'], 'archived': True})
        self.assertEqual(response.status_code, 200, response.text)
        archived = response.json()
        validate_contract(archived, 'Asset')
        self.assertIsNotNone(archived['archivedAt'])
        for field in ['name', 'note', 'favorite', 'tags', 'collections', 'files', 'state', 'trashedAt']:
            self.assertEqual(archived[field], asset[field], field)
        for c in collections:
            self.assertEqual(self.vault.list_assets(collection=c['id'])['total'], 0)
            self.assertEqual(self.vault.list_assets(collection=c['id'], archive='archived')['total'], 1)
        self.assertEqual(self.vault.list_assets(view='favorites')['total'], 0)
        self.assertEqual(self.vault.list_assets(view='favorites', archive='all')['total'], 1)
        self.assertEqual(self.vault.list_assets(q='keep', view='archive')['total'], 1)
        status = self.vault.status()
        self.assertEqual((status['normalCount'], status['archiveCount'], status['assetCount'], status['byteSize']), (0, 1, 1, size))
        for entry in archived['files']:
            content = self.client.get(f'/api/v1/assets/{asset["id"]}/files/{entry["id"]}/content')
            self.assertEqual(content.status_code, 200)
            self.assertEqual(hashlib.sha256(content.content).hexdigest(), entry['sha256'])
        selection = [{'id': archived['id'], 'revision': archived['revision']}]
        self.assertEqual(self.client.post('/api/v1/bulk-download', json={'assets': selection}).status_code, 200)
        self.assertEqual(self.vault.asset(asset['id'])['archivedAt'], archived['archivedAt'])
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertEqual(restarted.asset(asset['id'])['archivedAt'], archived['archivedAt'])
        trashed = self.vault.trash(asset['id'], archived['revision'])
        self.assertEqual(self.vault.list_assets(view='archive')['total'], 0)
        self.assertEqual(self.vault.list_assets(view='trash')['total'], 1)
        self.assertEqual(self.client.post(f'/api/v1/assets/{asset["id"]}/archive', json={'revision': trashed['revision'], 'archived': False}).status_code, 400)
        restored = self.vault.trash(asset['id'], trashed['revision'], restore=True)
        self.assertEqual(restored['archivedAt'], archived['archivedAt'])
        normal = self.vault.archive_asset(asset['id'], {'revision': restored['revision'], 'archived': False})
        self.assertIsNone(normal['archivedAt'])
        self.assertEqual(self.vault.list_assets()['total'], 1)

    def test_bulk_archive_atomic_conflict_validation_and_noop(self):
        ids = [self.upload(image_bytes(color))['items'][0]['assetId'] for color in ['red', 'blue']]
        with self.vault.repo.connect() as db:
            db.executemany("UPDATE assets SET storageLocation='development-remote' WHERE id=?", [(i,) for i in ids])
        selection = [{'id': i, 'revision': self.vault.asset(i)['revision']} for i in ids]
        self.vault.update(ids[1], {'revision': selection[1]['revision'], 'note': 'concurrent'})
        body = {'assets': selection, 'archived': True}
        self.assertEqual(self.client.post('/api/v1/bulk-archive', json=body).status_code, 409)
        self.assertEqual(self.vault.list_assets()['total'], 2)
        selection = [{'id': i, 'revision': self.vault.asset(i)['revision']} for i in ids]
        for entries, flag in [(selection, 'true'), (selection, 1), ([], True), (selection * 2, True), (selection * 51, True)]:
            self.assertEqual(self.client.post('/api/v1/bulk-archive', json={'assets': entries, 'archived': flag}).status_code, 400)
        result = self.client.post('/api/v1/bulk-archive', json={'assets': selection, 'archived': True})
        self.assertEqual(result.json(), {'updated': 2})
        validate_contract(result.json(), 'ArchiveResult')
        selection = [{'id': i, 'revision': self.vault.asset(i)['revision']} for i in ids]
        self.assertEqual(self.vault.bulk_archive({'assets': selection, 'archived': True}), {'updated': 0})
        self.assertEqual([self.vault.asset(i)['revision'] for i in ids], [a['revision'] for a in selection])
        self.assertEqual(self.vault.bulk_archive({'assets': selection, 'archived': False}), {'updated': 2})

    def test_archive_scope_pagination_and_cursor_binding(self):
        ids = [self.upload(image_bytes(color))['items'][0]['assetId'] for color in ['red', 'blue', 'green']]
        with self.vault.repo.connect() as db:
            db.executemany("UPDATE assets SET storageLocation='development-remote' WHERE id=?", [(i,) for i in ids])
        self.vault.archive_asset(ids[0], {'revision': 1, 'archived': True})
        self.assertEqual(self.client.get('/api/v1/assets?archive=invalid').status_code, 400)
        self.assertEqual(self.client.get('/api/v1/assets?archive=all').json()['total'], 3)
        cursor = self.vault.list_assets(limit=1)['nextCursor']
        self.assertIsNotNone(cursor)
        self.assertEqual(self.client.get('/api/v1/assets', params={'archive': 'all', 'cursor': cursor}).status_code, 400)
        self.assertEqual(self.client.get('/api/v1/assets', params={'view': 'archive', 'cursor': cursor}).status_code, 400)
        self.vault.archive_asset(ids[1], {'revision': 1, 'archived': True})
        first = self.vault.list_assets(view='archive', limit=1)
        second = self.vault.list_assets(view='archive', limit=1, cursor=first['nextCursor'])
        self.assertEqual({a['id'] for a in first['items'] + second['items']}, set(ids[:2]))

    def test_collection_archive_all_pages_and_preview_conflict(self):
        collection = self.vault.create_entity('collections', 'large')
        # Isolated metadata-only records exercise full-collection updates beyond selection/page limits.
        with self.vault.repo.connect() as db:
            for i in range(125):
                asset_id = f'large-{i:03d}'
                db.execute("INSERT INTO assets(id,libraryId,kind,name,createdAt,updatedAt) VALUES (?, 'local-library','image',?,'2026-10-07','2026-10-07')", (asset_id, asset_id))
                db.execute('INSERT INTO asset_collections VALUES (?,?)', (asset_id, collection['id']))
        summary = self.client.get(f'/api/v1/collections/{collection["id"]}/archive-summary').json()
        validate_contract(summary, 'CollectionArchiveSummary')
        self.assertEqual(summary['normalCount'], 125)
        self.vault.update('large-124', {'revision': 1, 'note': 'concurrent'})
        response = self.client.post(f'/api/v1/collections/{collection["id"]}/archive', json={'archived': True, 'token': summary['token']})
        self.assertEqual(response.status_code, 409)
        self.assertEqual(self.vault.list_assets(collection=collection['id'])['total'], 125)
        trashed = self.vault.trash('large-000', 1)
        summary = self.vault.collection_archive_summary(collection['id'])
        self.assertEqual(summary['normalCount'], 124)
        result = self.vault.archive_collection(collection['id'], {'archived': True, 'token': summary['token']})
        self.assertEqual(result, {'updated': 124})
        self.assertIsNone(self.vault.asset(trashed['id'])['archivedAt'])
        self.assertEqual(self.vault.list_assets(view='archive', collection=collection['id'])['total'], 124)
        summary = self.vault.collection_archive_summary(collection['id'])
        self.assertEqual(self.vault.archive_collection(collection['id'], {'archived': False, 'token': summary['token']}), {'updated': 124})
        summary = self.vault.collection_archive_summary(collection['id'])
        self.vault.update('large-124', {'revision': self.vault.asset('large-124')['revision'], 'collectionIds': []})
        self.assertEqual(self.client.post(f'/api/v1/collections/{collection["id"]}/archive', json={'archived': True, 'token': summary['token']}).status_code, 409)
        self.assertEqual(self.client.get('/api/v1/collections/missing/archive-summary').status_code, 404)

    def test_remote_archive_mixed_selection_collection_and_local_migration(self):
        local = self.asset()
        remote_id = self.upload(image_bytes('blue'))['items'][0]['assetId']
        remote = self.vault.transfer_original(remote_id, {'revision': 1, 'destination': 'development-remote', 'removeLocal': True})
        selection = [{'id': a['id'], 'revision': a['revision']} for a in [local, remote]]
        self.assertEqual(self.client.post('/api/v1/bulk-archive', json={'assets': selection, 'archived': True}).status_code, 400)
        self.assertIsNone(self.vault.asset(remote_id)['archivedAt'])
        collection = self.vault.create_entity('collections', 'mixed')
        for a in [local, remote]:
            self.vault.update(a['id'], {'revision': a['revision'], 'collectionIds': [collection['id']]})
        summary = self.vault.collection_archive_summary(collection['id'])
        self.assertEqual(summary['normalCount'], 1)
        self.assertEqual(self.vault.archive_collection(collection['id'], {'archived': True, 'token': summary['token']}), {'updated': 1})
        self.assertIsNone(self.vault.asset(local['id'])['archivedAt'])
        original = next(f for f in local['files'] if f['role'] == 'original')
        with self.vault.repo.connect() as db:
            db.execute("UPDATE assets SET archivedAt='2026-10-07' WHERE id=?", (local['id'],))
            db.execute('PRAGMA user_version=6')
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertIsNone(restarted.asset(local['id'])['archivedAt'])
        self.assertEqual(checksum(restarted.storage.path(original['objectKey'])), original['sha256'])
        self.assertIsNotNone(restarted.asset(remote_id)['archivedAt'])

    def test_v2_archive_migration_preserves_original(self):
        asset = self.asset()
        with self.vault.repo.connect() as db:
            db.execute('DROP INDEX asset_archive_order')
            db.execute('ALTER TABLE assets DROP COLUMN archivedAt')
            db.execute('PRAGMA user_version=2')
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        migrated = restarted.asset(asset['id'])
        self.assertIsNone(migrated['archivedAt'])
        self.assertEqual(migrated['files'], asset['files'])
        original = next(f for f in migrated['files'] if f['role'] == 'original')
        self.assertEqual(checksum(restarted.storage.path(original['objectKey'])), original['sha256'])

    def test_small_transparent_preview_preserves_alpha_and_size(self):
        image = Image.new('RGBA', (50, 50), (255, 0, 0, 0))
        image.putpixel((25, 25), (255, 0, 0, 128))
        stream = io.BytesIO(); image.save(stream, 'PNG')
        job = self.upload(stream.getvalue(), 'tiny.png')
        asset = self.vault.asset(job['items'][0]['assetId'])
        for file in asset['files']:
            self.assertEqual((file['width'], file['height']), (50, 50))
            if file['role'] != 'original':
                self.assertEqual(file['mimeType'], 'image/png')
                with Image.open(self.vault.storage.path(file['objectKey'])) as preview:
                    self.assertEqual(preview.getpixel((0, 0))[3], 0)
                    self.assertEqual(preview.getpixel((25, 25))[3], 128)

    def test_original_hash_contract_and_restart(self):
        data = image_bytes()
        job = self.upload(data)
        asset = self.vault.asset(job['items'][0]['assetId'])
        validate_contract(asset, 'Asset')
        self.assertEqual(len(asset['files']), 3)
        original = next(f for f in asset['files'] if f['role'] == 'original')
        response = self.client.get(f'/api/v1/assets/{asset["id"]}/files/{original["id"]}/content?download=true')
        self.assertEqual(response.content, data)
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertEqual(restarted.asset(asset['id'])['name'], 'study')

    def test_batch_duplicate_and_failure(self):
        response = self.client.post('/api/v1/imports', files=[('files', ('a.png', image_bytes())), ('files', ('copy.png', image_bytes())), ('files', ('broken.png', b'bad'))])
        self.assertEqual([i['state'] for i in response.json()['items']], ['ready', 'duplicate', 'failed'])
        self.assertEqual(self.vault.status()['assetCount'], 1)

    def test_organize_search_conflict_and_collection_delete(self):
        asset = self.asset()
        tag = self.client.post('/api/v1/tags', json={'name': 'wood'}).json()
        collection = self.client.post('/api/v1/collections', json={'name': 'project'}).json()
        response = self.client.patch('/api/v1/assets/' + asset['id'], json={'revision': 1, 'name': 'desk', 'note': 'warm light', 'favorite': True, 'tagIds': [tag['id']], 'collectionIds': [collection['id']]})
        self.assertEqual(response.status_code, 200, response.text)
        for term in ['wood', 'desk', 'warm', 'study']:
            self.assertEqual(self.client.get('/api/v1/assets', params={'q': term}).json()['total'], 1)
        self.assertEqual(self.client.patch('/api/v1/assets/' + asset['id'], json={'revision': 1, 'name': 'stale'}).status_code, 409)
        self.client.delete('/api/v1/collections/' + collection['id'])
        self.assertEqual(self.vault.asset(asset['id'])['collections'], [])
        self.assertEqual(self.vault.status()['assetCount'], 1)

    def test_trash_duplicate_restore_and_purge(self):
        asset = self.asset()
        self.client.post(f'/api/v1/assets/{asset["id"]}/trash', json={'revision': 1})
        self.assertEqual(self.vault.list_assets()['total'], 0)
        self.assertEqual(self.upload()['items'][0]['code'], 'trashed_duplicate')
        self.assertEqual(self.vault.list_assets(view='trash')['total'], 1)
        response = self.client.post(f'/api/v1/assets/{asset["id"]}/restore', json={'revision': 2})
        self.assertEqual(response.json()['trashedAt'], None)
        self.assertEqual(self.client.request('DELETE', f'/api/v1/assets/{asset["id"]}', json={'revision': 3}).status_code, 400)
        self.client.post(f'/api/v1/assets/{asset["id"]}/trash', json={'revision': 3})
        response = self.client.request('DELETE', f'/api/v1/assets/{asset["id"]}', json={'revision': 4})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.vault.list_assets(view='trash')['total'], 0)

    def test_disk_failure_retry(self):
        with patch.object(self.vault.storage, 'put', side_effect=OSError('disk full')):
            job = self.upload()
        self.assertEqual(job['items'][0]['code'], 'storage_error')
        response = self.client.post(f'/api/v1/imports/{job["id"]}/retry', json={})
        self.assertEqual(response.json()['items'][0]['state'], 'ready')
        self.assertEqual(response.json()['items'][0]['id'], job['items'][0]['id'])

    def test_delete_failure_recovers_on_restart(self):
        asset = self.asset()
        self.vault.trash(asset['id'], 1)
        with patch.object(self.vault.storage, 'delete', side_effect=OSError('disk unavailable')):
            self.assertEqual(self.client.request('DELETE', f'/api/v1/assets/{asset["id"]}', json={'revision': 2}).status_code, 507)
        self.assertEqual(self.vault.asset(asset['id'])['state'], 'deleting')
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        self.assertEqual(restarted.list_assets(view='trash')['total'], 0)

    def test_preview_failure_retains_original_and_retry(self):
        # Recognisable HEIC container without claiming pixel decode support.
        job = self.upload(b'\x00\x00\x00\x18ftypheic' + b'\x00' * 30, 'sample.heic')
        asset = self.vault.asset(job['items'][0]['assetId'])
        self.assertEqual(asset['files'][0]['state'], 'failed')
        original = next(f for f in asset['files'] if f['role'] == 'original')
        self.assertEqual(original['state'], 'ready')

    def test_pagination_filter_binding(self):
        for color in ['orange', 'blue', 'red']:
            self.upload(image_bytes(color))
        first = self.vault.list_assets(limit=2)
        second = self.vault.list_assets(limit=2, cursor=first['nextCursor'])
        self.assertEqual(len(first['items']) + len(second['items']), 3)
        self.assertFalse(set(a['id'] for a in first['items']) & set(a['id'] for a in second['items']))
        validate_contract(first, 'AssetPage')
        with self.assertRaises(VaultError):
            self.vault.list_assets(q='different', cursor=first['nextCursor'])

    def test_boundary_and_missing_file(self):
        self.assertEqual(self.client.get('/api/v1/status', headers={'host': 'evil.example'}).status_code, 403)
        self.assertEqual(self.client.post('/api/v1/tags', json={'name': 'bad'}, headers={'origin': 'https://evil.example'}).status_code, 403)
        with self.assertRaises(ValueError):
            self.vault.storage.path('../escape')
        asset = self.asset()
        original = next(f for f in asset['files'] if f['role'] == 'original')
        self.vault.storage.delete(original['objectKey'])
        self.assertEqual(self.vault.asset(asset['id'])['files'][1]['state'], 'missing')

    def test_fixture_source_unchanged(self):
        self.vault.fixtures.mkdir()
        source = self.vault.fixtures / 'source.png'
        source.write_bytes(image_bytes())
        before = checksum(source)
        self.assertEqual(self.vault.fixture_import()['items'][0]['state'], 'ready')
        self.assertEqual(checksum(source), before)

    def test_interrupted_import_recovery_and_backup(self):
        item_id = 'interrupted-item'
        job_id = self.vault.new_job()
        self.vault.staging.path(item_id).write_bytes(image_bytes())
        with self.vault.repo.connect() as db:
            db.execute('INSERT INTO import_items(id,jobId,filename,state,stageKey) VALUES (?,?,?,?,?)', (item_id, job_id, 'recover.png', 'processing', item_id))
        restarted = Vault(self.root / 'data', self.root / 'fixtures')
        result = restarted.job(job_id)
        self.assertEqual(result['items'][0]['state'], 'ready')
        # This isolated Vault has no live server or other active writers.
        shutil.copytree(self.root / 'data', self.root / 'backup')
        restored = Vault(self.root / 'backup', self.root / 'fixtures')
        asset = restored.asset(result['items'][0]['assetId'])
        original = next(f for f in asset['files'] if f['role'] == 'original')
        self.assertEqual(checksum(restored.storage.path(original['objectKey'])), original['sha256'])

    def test_preview_disk_failure_then_regeneration(self):
        real_put = self.vault.storage.put
        calls = 0
        def fail_derivatives(source, key):
            nonlocal calls
            calls += 1
            if calls > 1:
                raise OSError('disk full')
            return real_put(source, key)
        with patch.object(self.vault.storage, 'put', side_effect=fail_derivatives):
            job = self.upload()
        self.assertEqual(job['items'][0]['state'], 'ready')
        asset = self.vault.asset(job['items'][0]['assetId'])
        self.assertEqual([f['state'] for f in asset['files']].count('failed'), 2)
        self.assertTrue(all(f['state'] == 'ready' for f in self.vault.preview(asset['id'])['files']))

    def test_shared_example_matches_schema_and_generated_code(self):
        validate_contract(json.loads((ROOT / 'contracts/asset.example.json').read_text(encoding='utf-8')), 'Asset')
        self.assertEqual((ROOT / 'contracts/asset.example.json').read_text(encoding='utf-8'), (ROOT / 'Tests/AssetLibraryContractTests/asset.json').read_text(encoding='utf-8'))

    def test_invalid_relationship_rolls_back_name(self):
        asset = self.asset()
        response = self.client.patch('/api/v1/assets/' + asset['id'], json={'revision': 1, 'name': 'should roll back', 'tagIds': ['missing']})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.vault.asset(asset['id'])['name'], 'study')

    def test_stream_size_limit_and_no_unbounded_body(self):
        with patch('vault.service.MAX_BYTES', 10):
            job = self.upload()
        self.assertEqual(job['items'][0]['code'], 'too_large')
        response = self.client.post('/api/v1/imports', content=iter([b'a']), headers={'content-type': 'multipart/form-data; boundary=test'})
        self.assertEqual(response.status_code, 411)


if __name__ == '__main__':
    unittest.main()
