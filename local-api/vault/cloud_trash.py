"""Explicit Mac trash mutations. Catalog CAS precedes destructive S3 work."""
import base64
import hashlib
import json
from pathlib import Path
import tempfile
import uuid
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

from .folder_upload import atomic_json
from .service import VaultError
from .folder_privacy import security
import catalog_trash


class CloudTrash:
    def __init__(self, uploads):
        self.uploads = uploads
        self.synced = {}

    def sync_library(self):
        # Keep the same exclusion against upload/trash writes, but fetch independent
        # catalogs concurrently. Only successful reads earn a short-lived cache.
        with self.uploads.lock:
            plans = [self.uploads.read(p['id']) for p in self.uploads.list()]
            with ThreadPoolExecutor(max_workers=3) as pool:
                list(pool.map(self.sync_cached, plans))

    def sync_cached(self, plan):
        key = (plan['bucket'], plan['profile'], plan['region'], plan['id'])
        if time.monotonic() < self.synced.get(key, 0):
            return plan
        result = self.sync(plan)
        if plan['state'] == 'complete':
            self.synced[key] = time.monotonic() + 30
        return result

    def load(self, plan):
        client = self.uploads.client_factory(plan['bucket'], plan['profile'], plan['region'])
        key = f'media-hub/catalogs/{plan["rootId"]}/{plan["id"]}.json'
        head = client.head(key)
        if not head or not 0 < head['ContentLength'] <= 4 * 1024 ** 2:
            raise VaultError('integrity', 'S3の一覧情報を確認できません。', 409)
        with tempfile.TemporaryDirectory(dir=self.uploads.root, prefix='trash-read-') as temp:
            path = Path(temp) / 'catalog.json'
            client.download(key, head.get('VersionId'), path)
            if path.stat().st_size > 4 * 1024 ** 2:
                raise VaultError('integrity', '一覧情報が大きすぎます。', 409)
            value = json.loads(path.read_text())
        if value.get('id') != plan['id'] or value.get('rootId') != plan['rootId']:
            raise VaultError('integrity', '一覧情報の識別子が一致しません。', 409)
        catalog_trash.validate(value)
        expected = {i['id']: (i['objectKey'], i['sha256'], i['folderId']) for i in plan['items']}
        actual = {i['id']: (i['objectKey'], i['sha256'], i['folderId']) for i in value['items']}
        if expected != actual or {f['id']: f.get('parentId') for f in plan['folders']} != {f['id']: f.get('parentId') for f in value['folders']}:
            raise VaultError('integrity', '一覧情報が送信記録と一致しません。操作を停止しました。', 409)
        created = value.get('catalogCreatedAt')
        if created is None:
            modified = head.get('LastModified')
            created = datetime.fromisoformat(modified.replace('Z', '+00:00')).timestamp() if modified else self.uploads.path(plan['id']).stat().st_mtime
        plan.setdefault('catalogCreatedAt', created)
        return client, key, head['ETag'], value

    def save(self, client, key, etag, value, plan):
        self.synced.clear()
        value['catalogCreatedAt'] = plan['catalogCreatedAt']
        with tempfile.TemporaryDirectory(dir=self.uploads.root, prefix='trash-save-') as temp:
            path = Path(temp) / 'catalog.json'
            atomic_json(path, value)
            if path.stat().st_size > 4 * 1024 ** 2:
                raise VaultError('too_large', '一覧情報が大きすぎます。', 413)
            digest = base64.b64encode(hashlib.sha256(path.read_bytes()).digest()).decode()
            client.put(path, key, digest, 'application/json', etag=etag)
            head = client.head(key)
            if not head or head.get('ChecksumSHA256') != digest:
                raise VaultError('integrity', '保存を照合できません。更新して確認してください。', 409)
        plan['trash'] = value.get('trash', [])
        self.uploads.save(plan)

    def sync(self, plan):
        if plan['state'] == 'complete' and not plan.get('noCatalog'):
            _, _, _, value = self.load(plan)
            plan['trash'] = value.get('trash', [])
            self.uploads.save(plan)
        return plan

    def entries(self, token, privacy=None):
        results = []
        with self.uploads.lock:
            for summary in self.uploads.list():
                plan = self.sync(self.uploads.read(summary['id']))
                if plan['state'] != 'complete':
                    continue
                if privacy:
                    try:
                        visible = privacy.plan(plan['id'], token)
                    except VaultError as error:
                        if error.code == 'not_found':
                            continue
                        raise
                    allowed_folders = {f['id'] for f in visible['folders']}
                else:
                    allowed_folders = {f['id'] for f in plan['folders']}
                items = {i['id']: i for i in plan['items']}
                for entry in plan.get('trash', []):
                    required = set(entry['folderIds']) | {items[i]['folderId'] for i in entry['itemIds'] if i in items}
                    if entry['state'] != 'purged' and required <= allowed_folders:
                        results.append({k: entry[k] for k in ('id', 'name', 'state', 'itemIds', 'folderIds')} | {'planId': plan['id'], 'byteSize': sum(items[i]['byteSize'] for i in entry['itemIds'] if i in items)})
        return results

    def mutate(self, plan_id, body):
        with self.uploads.lock:
            plan = self.uploads.read(plan_id)
            if plan['state'] != 'complete' or self.uploads.running:
                raise VaultError('conflict', '送信を停止し、保存完了後に操作してください。', 409)
            client, key, etag, value = self.load(plan)
            client.verify_private()
            entries = value.setdefault('trash', [])
            action = body.get('action')
            if body.get('confirm') is not True:
                raise VaultError('invalid_request', '対象と操作を確認してください。')
            if action == 'trash':
                if set(body) != {'action', 'confirm', 'itemIds', 'folderId'}:
                    raise VaultError('invalid_request', '削除対象が不正です。')
                current = catalog_trash.active(value)
                if current is None:
                    raise VaultError('conflict', 'このフォルダはごみ箱にあります。', 409)
                ids = body['itemIds']
                if not isinstance(ids, list) or any(not isinstance(i, str) for i in ids) or len(set(ids)) != len(ids):
                    raise VaultError('invalid_request', '素材の選択が不正です。')
                selected = set(ids)
                folders = set()
                folder = body['folderId']
                if folder is not None:
                    if selected or not any(f['id'] == folder for f in current['folders']):
                        raise VaultError('invalid_request', 'フォルダの選択が不正です。')
                    folders.add(folder)
                    while True:
                        expanded = folders | {f['id'] for f in current['folders'] if f.get('parentId') in folders}
                        if expanded == folders:
                            break
                        folders = expanded
                    selected = {i['id'] for i in current['items'] if i['folderId'] in folders}
                if not (selected or folders) or not selected <= {i['id'] for i in current['items']}:
                    raise VaultError('invalid_request', '保存済みの対象を選択してください。')
                # A folder cannot overlap an existing trash entry; restore those entries first.
                if any(set(e['folderIds']) & folders or any(i['id'] in e['itemIds'] and i['folderId'] in folders for i in value['items']) for e in entries if e['state'] != 'purged'):
                    raise VaultError('conflict', '先にこのフォルダ内のごみ箱項目を復元してください。', 409)
                name = next(f['name'] for f in current['folders'] if f['id'] == folder) if folder else (next(i['name'] for i in current['items'] if i['id'] in selected) if len(selected) == 1 else f'{len(selected)}個のファイル')
                entries.append(dict(id=str(uuid.uuid4()), name=name, state='trashed', itemIds=sorted(selected), folderIds=sorted(folders)))
                self.save(client, key, etag, value, plan)
            elif action in ('restore', 'purge'):
                if set(body) != {'action', 'confirm', 'entryId'}:
                    raise VaultError('invalid_request', '操作が不正です。')
                entry = next((e for e in entries if e['id'] == body['entryId']), None)
                if not entry:
                    raise VaultError('not_found', 'ごみ箱項目が見つかりません。', 404)
                if action == 'restore':
                    if entry['state'] != 'trashed':
                        raise VaultError('conflict', '完全削除を開始した項目は復元できません。', 409)
                    entries.remove(entry)
                    self.save(client, key, etag, value, plan)
                elif entry['state'] != 'purged':
                    selected = [i for i in value['items'] if i['id'] in entry['itemIds']]
                    keys = set()
                    for item in selected:
                        expected = f'media-hub/originals/{item["id"]}/{item["sha256"]}'
                        if item['objectKey'] != expected or not security.valid_uuid(item['id']) or len(item['sha256']) != 64 or any(c not in '0123456789abcdef' for c in item['sha256']):
                            raise VaultError('integrity', '削除先を確認できません。', 409)
                        keys.add(expected)
                        thumb = item.get('thumbnailKey')
                        if thumb:
                            if thumb != f'media-hub/thumbnails/{item["id"]}/{item["sha256"]}.png':
                                raise VaultError('integrity', '小画像の削除先を確認できません。', 409)
                            keys.add(thumb)
                    client.require_unreferenced(keys, key)
                    if entry['state'] == 'trashed':
                        entry['state'] = 'deleting'
                        self.save(client, key, etag, value, plan)
                    for object_key in sorted(keys):
                        client.purge_versions(object_key)
                    client, key, etag, value = self.load(plan)
                    entry = next(e for e in value['trash'] if e['id'] == body['entryId'])
                    entry['state'] = 'purged'
                    self.save(client, key, etag, value, plan)
            else:
                raise VaultError('invalid_request', '操作が不正です。')
            return {'saved': True}
