"""Mac administration of shared folder locks. Never records plaintext passwords."""
import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import threading
import uuid
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'backend'))
import folder_security as security
from .folder_upload import S3CLI
from .service import VaultError


class FolderPrivacy:
    def __init__(self, uploads):
        self.uploads = uploads
        self.lock = threading.RLock()
        self.last_unlock = 0

    def destination(self):
        plans = self.uploads.list()
        if not plans:
            raise VaultError('missing_destination', '保存先を先に設定してください。', 409)
        buckets = {(p['bucket'], p['region']) for p in plans}
        if len(buckets) != 1:
            raise VaultError('ambiguous_destination', '初期版の鍵は保存先1つに対応します。', 409)
        plan = plans[0]
        return self.uploads.client_factory(plan['bucket'], plan['profile'], plan['region'])

    def load(self):
        client = self.destination()
        head = client.head(security.KEY)
        if not head or not 0 < head.get('ContentLength', 0) <= 65536:
            raise VaultError('invalid_settings', '鍵設定を読み取れません。閲覧を停止しました。', 409)
        with tempfile.TemporaryDirectory(dir=self.uploads.root, prefix='locks-read-') as temp:
            path = Path(temp) / 'settings.json'
            metadata = client.download(security.KEY, head.get('VersionId'), path)
            if path.stat().st_size > 65536:
                raise VaultError('invalid_settings', '鍵設定を読み取れません。閲覧を停止しました。', 409)
            try:
                settings = security.validate(json.loads(path.read_text()))
            except (ValueError, KeyError, TypeError):
                raise VaultError('invalid_settings', '鍵設定を読み取れません。閲覧を停止しました。', 409)
        return client, settings, metadata['ETag']

    def visible(self, plan, settings, token):
        return security.visible(plan, settings, security.grants(settings, token, 'desktop'))

    def library(self, token):
        if not self.uploads.list():
            return []
        _, settings, _ = self.load()
        results = []
        for summary in self.uploads.library():
            plan = self.uploads.read(summary['id'])
            import catalog_trash
            active = catalog_trash.active(plan)
            value = self.visible(active, settings, token) if active is not None else None
            if value is not None:
                value['byteSize'] = sum(item['byteSize'] for item in value['items'])
                if len(value['folders']) != len(plan['folders']):
                    value['skipped'] = 0
                results.append(self.uploads.public(value))
        return results

    def plan(self, plan_id, token):
        _, settings, _ = self.load()
        value = self.visible(self.uploads.read(plan_id), settings, token)
        if value is None:
            raise VaultError('not_found', 'フォルダが見つかりません。', 404)
        value['byteSize'] = sum(item['byteSize'] for item in value['items'])
        value['skipped'] = 0
        return self.uploads.public(value)

    def plans(self, token):
        if not self.uploads.list():
            return []
        _, settings, _ = self.load()
        results = []
        for summary in self.uploads.list():
            value = self.visible(self.uploads.read(summary['id']), settings, token)
            if value is not None:
                value['byteSize'] = sum(item['byteSize'] for item in value['items'])
                value['skipped'] = 0
                results.append(self.uploads.public(value))
        return results

    def authorize(self, plan_id, item_id, token):
        _, settings, _ = self.load()
        plan = self.uploads.read(plan_id)
        value = self.visible(plan, settings, token)
        if value is None or not any(item['id'] == item_id for item in value['items']):
            raise VaultError('not_found', '素材が見つかりません。', 404)

    def unlock(self, body, token):
        if set(body) != {'password'}:
            raise VaultError('invalid_request', 'パスワードを入力してください。')
        try:
            security.password_bytes(body['password'])
        except ValueError:
            raise VaultError('invalid_password', '半角数字6桁のPINを入力してください。全角数字や空白は使えません。', 400)
        with self.lock:
            now = time.monotonic()
            if now - self.last_unlock < 5:
                raise VaultError('retry_later', '5秒ほど待ってから再試行してください。', 429)
            self.last_unlock = now
        _, settings, _ = self.load()
        try:
            return security.unlock(settings, body['password'], 'desktop', token)
        except ValueError:
            raise VaultError('cannot_unlock', '保存された鍵と入力が一致しません。設定した半角数字6桁のPINを確認してください。', 403)

    def require_full_plan(self, plan_id, token):
        _, settings, _ = self.load()
        plan = self.uploads.read(plan_id)
        value = self.visible(plan, settings, token)
        if value is None or len(value['folders']) != len(plan['folders']):
            raise VaultError('folder_locked', '先に鍵付きフォルダを解除してください。', 403)

    def set(self, body, token):
        if set(body) != {'planId', 'folderId', 'password', 'confirmSave'} or body['confirmSave'] is not True:
            raise VaultError('invalid_request', '鍵設定の保存を確認してください。')
        with self.lock:
            client, settings, etag = self.load()
            plan = self.uploads.read(body['planId'])
            value = self.visible(plan, settings, token)
            if value is None or not any(folder['id'] == body['folderId'] for folder in value['folders']):
                raise VaultError('not_found', '先にフォルダを解除してください。', 404)
            locks = [lock for lock in settings['locks'] if lock['folderId'] != body['folderId']]
            if body['password'] is not None:
                try:
                    locks.append(security.make_lock(plan['rootId'], body['folderId'], body['password']))
                except ValueError:
                    raise VaultError('invalid_password', '半角数字6桁のPINを設定してください。')
            if len(locks) > security.MAX_LOCKS:
                raise VaultError('too_many_locks', '初期版の鍵は10フォルダまでです。', 409)
            settings.update(locks=locks, revision=str(uuid.uuid4()))
            client.verify_private()
            with tempfile.TemporaryDirectory(dir=self.uploads.root, prefix='locks-save-') as temp:
                path = Path(temp) / 'settings.json'
                path.write_text(json.dumps(settings)); path.chmod(0o600)
                digest = base64.b64encode(hashlib.sha256(path.read_bytes()).digest()).decode()
                client.put(path, security.KEY, digest, 'application/json', etag=etag)
                remote = client.head(security.KEY)
                if remote.get('ChecksumSHA256') != digest:
                    raise VaultError('integrity', '保存の照合ができません。鍵設定を確認してください。', 409)
            return {'saved': True}
