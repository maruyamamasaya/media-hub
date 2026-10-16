"""Content duplicate checks against authoritative S3 catalogs, before media writes."""
import base64
from collections import OrderedDict
import threading
from datetime import datetime
import json
from pathlib import Path
import re
import tempfile
import uuid

from .service import VaultError
from catalog_limits import MAX_CATALOG_BYTES, MAX_ENCRYPTED_CATALOG_BYTES

MAX_CATALOG = MAX_CATALOG_BYTES
MAX_SCAN_DOWNLOAD_BYTES = 64 * 1024 ** 2
MAX_SCAN_CATALOGS = 2000


class CatalogCache:
    """Bounded, process-only bytes; encrypted catalogs remain ciphertext."""
    def __init__(self, maximum_bytes=64 * 1024 ** 2):
        self.maximum_bytes = maximum_bytes
        self.entries = OrderedDict()
        self.byte_size = 0
        self.lock = threading.Lock()

    def get(self, key):
        with self.lock:
            value = self.entries.get(key)
            if value is not None:
                self.entries.move_to_end(key)
            return value

    def put(self, key, value):
        if len(value) > self.maximum_bytes:
            return
        with self.lock:
            previous = self.entries.pop(key, None)
            self.byte_size -= len(previous) if previous is not None else 0
            self.entries[key] = value
            self.byte_size += len(value)
            while self.byte_size > self.maximum_bytes:
                _, evicted = self.entries.popitem(last=False)
                self.byte_size -= len(evicted)


def valid_id(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def catalogs(client, prefix, root, decode=None, cache=None, scope=None):
    from catalog_trash import validate as catalog_trash_validate
    token = None
    downloaded = count = 0
    for _ in range(100):
        args = ['--prefix', prefix, '--no-paginate', '--max-keys', '1000']
        if token:
            args += ['--continuation-token', token]
        page = client.call('list-objects-v2', *args)
        for entry in page.get('Contents', []):
            object_key = entry['Key']
            parts = object_key[len(prefix):].split('/')
            if decode:
                if len(parts) != 1 or not parts[0].endswith('.bin') or not valid_id(parts[0][:-4]):
                    continue
                identity = parts[0][:-4]
            else:
                if len(parts) != 2 or not valid_id(parts[0]) or not parts[1].endswith('.json') or not valid_id(parts[1][:-5]):
                    continue
                identity = parts[1][:-5]
            count += 1
            if count > MAX_SCAN_CATALOGS:
                raise VaultError('duplicate_check_limit', '重複確認の一覧が2,000件を超えたため、追加送信を停止しました。', 413)
            head = client.head(object_key)
            limit = MAX_ENCRYPTED_CATALOG_BYTES if decode else MAX_CATALOG
            if not head or not 0 < head['ContentLength'] <= limit:
                raise VaultError('integrity', '重複確認用の一覧情報を読み取れません。', 409)
            # Revalidate current metadata every time; never reuse across destinations or revisions.
            etag, version = head.get('ETag'), head.get('VersionId')
            cache_key = (scope, object_key, version, etag, head['ContentLength']) if etag else None
            raw = cache.get(cache_key) if cache is not None and cache_key is not None else None
            if raw is None:
                if downloaded + head['ContentLength'] > MAX_SCAN_DOWNLOAD_BYTES:
                    raise VaultError('duplicate_check_limit', '重複確認のダウンロードが64MiBを超えるため、追加送信を停止しました。', 413)
                downloaded += head['ContentLength']
                with tempfile.TemporaryDirectory(dir=root, prefix='duplicate-read-') as temp:
                    path = Path(temp) / 'catalog'
                    client.download(object_key, version, path)
                    if path.stat().st_size != head['ContentLength'] or path.stat().st_size > limit:
                        raise VaultError('integrity', '重複確認用の一覧情報が不正です。', 409)
                    raw = path.read_bytes()
            if decode:
                with tempfile.TemporaryDirectory(dir=root, prefix='duplicate-read-') as temp:
                    path = Path(temp) / 'catalog'
                    path.write_bytes(raw)
                    value = decode(path, identity)
            else:
                value = json.loads(raw)
            if value.get('schemaVersion') != 1 or value.get('id') != identity or not isinstance(value.get('items'), list) or not isinstance(value.get('folders'), list):
                raise VaultError('integrity', '重複確認用の一覧情報が不正です。', 409)
            if len(value['items']) > 10000 or len(value['folders']) > 10000:
                raise VaultError('integrity', '重複確認用の一覧情報が大きすぎます。', 409)
            if not decode and value.get('rootId') != parts[0]:
                raise VaultError('integrity', '重複確認用の一覧情報の識別子が不正です。', 409)
            folder_ids = {f.get('id') for f in value['folders']}
            if (not isinstance(value.get('name'), str) or not folder_ids or
                    len(folder_ids) != len(value['folders']) or not all(valid_id(i) for i in folder_ids) or
                    sum(f.get('parentId') is None for f in value['folders']) != 1):
                raise VaultError('integrity', '重複確認用のフォルダ情報が不正です。', 409)
            parents = {f['id']: f.get('parentId') for f in value['folders']}
            for folder in value['folders']:
                node, visited = folder['id'], set()
                while node is not None:
                    if node not in parents or node in visited:
                        raise VaultError('integrity', '重複確認用のフォルダ階層が不正です。', 409)
                    visited.add(node)
                    node = parents[node]
                if not isinstance(folder.get('name'), str):
                    raise VaultError('integrity', '重複確認用のフォルダ名が不正です。', 409)
            catalog_trash_validate(value)
            item_ids = set()
            for item in value['items']:
                if (not valid_id(item.get('id')) or not isinstance(item.get('sha256'), str) or
                        not re.fullmatch('[0-9a-f]{64}', item['sha256']) or
                        type(item.get('byteSize')) is not int or not 0 < item['byteSize'] <= 5 * 1024 ** 3 or
                        item.get('folderId') not in folder_ids or item['id'] in item_ids or
                        not isinstance(item.get('name'), str) or not isinstance(item.get('mimeType'), str)):
                    raise VaultError('integrity', '重複確認用の素材情報が不正です。', 409)
                item_ids.add(item['id'])
                if not decode and item.get('objectKey') != f'media-hub/originals/{item["id"]}/{item["sha256"]}':
                    raise VaultError('integrity', '重複確認用の素材の保存先が不正です。', 409)
            modified = entry.get('LastModified', head.get('LastModified', '1970-01-01T00:00:00Z'))
            rank = value.get('catalogCreatedAt', datetime.fromisoformat(modified.replace('Z', '+00:00')).timestamp())
            if cache is not None and cache_key is not None:
                cache.put(cache_key, raw)
            yield value, rank
        following = page.get('NextContinuationToken')
        if not following:
            return
        if following == token:
            break
        token = following
    raise VaultError('too_large', '重複確認用の一覧が多すぎます。送信を停止しました。', 413)


def prepare(uploads, plan, client, decode=None, key_id=None):
    """Keep skipped candidates in the journal so a failed/paused plan can recheck."""
    import catalog_trash
    prefix = f'media-hub/encrypted-catalogs/{key_id}/' if decode else 'media-hub/catalogs/'
    uploads.live[plan['id']] = {'phase': 'duplicates', 'name': '', 'bytes': 0, 'totalBytes': plan['byteSize'], 'remainingSeconds': None, 'activeFiles': 0}
    loaded = []
    scope = (plan['bucket'], plan['profile'], plan['region'], key_id)
    for value in catalogs(client, prefix, uploads.root, decode, uploads.duplicate_catalog_cache, scope):
        if uploads.stopped(plan['id']):
            from .folder_upload import TransferPaused
            raise TransferPaused()
        loaded.append(value)
    latest = {}
    if not decode:
        for value, rank in loaded:
            if value['rootId'] not in latest or rank > latest[value['rootId']][1]:
                latest[value['rootId']] = (value, rank)
    candidates = [i for i in plan['items'] if not i.get('retained')] + plan.get('duplicateItems', [])
    requested = {(i['sha256'], i['byteSize']): i for i in candidates}
    known, retained, folders = set(), [], []
    for value, _ in loaded:
        if value['id'] == plan['id']:
            continue  # Reconcile our own interrupted commit using the existing upload path.
        purged = {i for e in value.get('trash', []) if e['state'] == 'purged' for i in e['itemIds']}
        for item in value['items']:
            if item['id'] in purged or (item['sha256'], item['byteSize']) not in requested or (item['sha256'], item['byteSize']) in known:
                continue
            if decode:
                object_key = f'media-hub/encrypted-objects/{key_id}/{value["id"]}/{item["objectID"]}.bin'
                remote = client.head(object_key)
                expected = 60 + item['byteSize'] + ((item['byteSize'] + 1048575) // 1048576) * 16
                if not remote or remote['ContentLength'] != expected:
                    continue
            else:
                remote = client.head(item['objectKey'])
                if not remote:
                    continue
                from .folder_upload import remote_matches
                candidate = requested[(item['sha256'], item['byteSize'])]
                if not remote_matches(remote, item['byteSize'], base64.b64encode(bytes.fromhex(item['sha256'])).decode(), candidate.get('multipartSHA256')):
                    raise VaultError('integrity', '保存済み原本の照合に失敗しました。重複確認のため送信を停止しました。', 409)
            known.add((item['sha256'], item['byteSize']))
        if not decode and value['rootId'] == plan['rootId'] and value is latest[value['rootId']][0]:
            active = catalog_trash.active(value)
            if active:
                retained, folders = active['items'], active['folders']
    accepted, duplicates = [], []
    seen = set(known)
    for item in candidates:
        content = (item['sha256'], item['byteSize'])
        # Verified work in this interrupted plan must still reach its catalog.
        if content in seen and item['state'] != 'verified':
            duplicates.append(item)
        else:
            accepted.append(item)
            seen.add(content)
    plan['duplicateItems'] = duplicates
    plan['duplicateCount'] = len(duplicates)
    plan['noCatalog'] = bool(duplicates and not accepted)
    if accepted and retained:
        ids = {i['id'] for i in accepted}
        for item in retained:
            if item['id'] not in ids:
                accepted.append(dict(item, relativePath=item['name'], state='verified', retained=True))
        folder_ids = {f['id'] for f in plan['folders']}
        plan['folders'] += [f for f in folders if f['id'] not in folder_ids]
    plan['items'] = accepted
    plan['byteSize'] = sum(i['byteSize'] for i in accepted)
    if len(accepted) > 10000 or len(plan['folders']) > 10000:
        raise VaultError('too_large', '保存済み素材を含むフォルダが10,000件を超えます。', 413)
    uploads.check_catalog_capacity(plan)
    with uploads.lock:
        plan['stop'] = uploads.read(plan['id'])['stop']
        uploads.save(plan)
