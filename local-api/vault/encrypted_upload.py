"""Separate, explicit client-encrypted transfers. Keys exist only in memory/stdin."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import uuid

from .folder_upload import FolderUploads, S3CLI, atomic_json, signature, hash_stream, remote_matches, TransferPaused, MULTIPART_THRESHOLD
from .service import VaultError

ROOT = Path(__file__).resolve().parents[2]


class EncryptedUploads:
    def __init__(self, root, client_factory=S3CLI, helper=None):
        self.uploads = FolderUploads(Path(root) / 'sealed')
        self.uploads.sealed_catalog = True
        self.uploads.client_factory = client_factory
        self.helper = Path(helper or os.getenv('MEDIA_HUB_CRYPTO_HELPER', ROOT / '.local/Media Hub.app/Contents/Resources/MediaHubCrypto'))

    @staticmethod
    def secret(body):
        if set(body) != {'confirmUpload', 'keyID', 'masterKey'} or body['confirmUpload'] is not True:
            raise VaultError('invalid_request', '暗号化送信の内容を確認してください。')
        try:
            key_id = str(uuid.UUID(body['keyID']))
            key = base64.b64decode(body['masterKey'], validate=True)
            if key_id != body['keyID'] or len(key) != 32:
                raise ValueError()
        except (ValueError, TypeError, KeyError):
            raise VaultError('invalid_key', '暗号化の鍵を確認してください。')
        return key_id, key

    def list(self):
        return self.uploads.list()

    def scan(self, body, progress=None):
        result = self.uploads.scan(body, progress=progress)
        raw = self.uploads.read(result['id'])
        # Normal object keys are never used by this service.
        for item in raw['items']:
            item.pop('objectKey', None)
        self.uploads.save(raw)
        return self.uploads.public(raw)

    def start(self, plan_id, body):
        key_id, key = self.secret(body)
        if not self.helper.is_file():
            raise VaultError('crypto_unavailable', '暗号化処理を準備できません。アプリを更新してください。', 503)
        with self.uploads.lock:
            plan = self.uploads.read(plan_id)
            if self.uploads.running:
                raise VaultError('conflict', '暗号化送信の完了または停止を待ってください。', 409)
            if plan.get('keyID') not in (None, key_id):
                raise VaultError('invalid_key', 'この送信で使用した鍵が必要です。', 409)
            fingerprint = hashlib.sha256(b'media-hub/key-identity/v1' + key).hexdigest()
            if plan.get('keyFingerprint') not in (None, fingerprint):
                raise VaultError('invalid_key', '前回の送信と同じ復号鍵が必要です。', 409)
            if plan['state'] == 'complete':
                return self.uploads.public(plan)
            self.uploads.check_catalog_capacity(plan)
            plan.update(keyID=key_id, keyFingerprint=fingerprint, state='uploading', error='', stop=False)
            self.uploads.save(plan); self.uploads.running.add(plan_id)
            threading.Thread(target=self.upload, args=(plan_id, key_id, key), daemon=True).start()
            return self.uploads.public(plan)

    def start_queue(self, plan_ids, body):
        key_id, key = self.secret(body)
        if not self.helper.is_file():
            raise VaultError('crypto_unavailable', '暗号化処理を準備できません。', 503)
        fingerprint = hashlib.sha256(b'media-hub/key-identity/v1' + key).hexdigest()
        def validate(plan):
            if plan.get('keyID') not in (None, key_id) or plan.get('keyFingerprint') not in (None, fingerprint):
                raise VaultError('invalid_key', '前回と同じ暗号化の鍵が必要です。', 409)
        with self.uploads.lock:
            # Validate every plan before binding any; no key material enters the queue journal.
            if not isinstance(plan_ids, list) or any(not isinstance(i, str) for i in plan_ids):
                raise VaultError('invalid_request', 'フォルダを指定してください。')
            for plan_id in plan_ids:
                validate(self.uploads.read(plan_id))
            def bind(plan):
                validate(plan)
                plan.update(keyID=key_id, keyFingerprint=fingerprint)
            return self.uploads.start_queue(plan_ids, {'confirmUpload': True},
                lambda plan_id: self.upload(plan_id, key_id, key), bind)

    def encrypt(self, source, output, object_id, key):
        payload = json.dumps({'source': str(source), 'output': str(output), 'objectID': object_id, 'masterKey': base64.b64encode(key).decode()})
        result = subprocess.run([str(self.helper)], input=payload, capture_output=True, text=True, timeout=7200)
        if result.returncode:
            raise VaultError('crypto_error', '暗号化処理に失敗しました。元ファイルは変更していません。', 502)
        try:
            metadata = json.loads(result.stdout)
            if output.stat().st_size != metadata['byteSize']:
                raise ValueError()
            with output.open('rb') as stream:
                digest, composite = hash_stream(stream)
                if base64.b64encode(bytes.fromhex(digest)).decode() != metadata['checksum']:
                    raise ValueError()
                metadata['multipartSHA256'] = composite
        except (ValueError, KeyError, OSError):
            raise VaultError('integrity', '暗号化結果の照合に失敗しました。', 409)
        return metadata

    def put(self, client, source, object_id, key_id, plan, item, key):
        plan_id = plan['id']
        object_key = f'media-hub/encrypted-objects/{key_id}/{plan_id}/{object_id}.bin'
        remote = client.head(object_key)
        length = source.stat().st_size
        expected_length = 60 + length + ((length + 1048575) // 1048576) * 16
        # Only ciphertext survives an interrupted multipart transfer. Plain staging remains temporary.
        persistent = expected_length >= MULTIPART_THRESHOLD
        directory = self.uploads.path(plan_id).parent / 'ciphertext' if persistent else source.parent
        directory.mkdir(parents=True, exist_ok=True)
        encrypted = directory / (object_id + '.sealed')
        meta_path = directory / (object_id + '.json')
        metadata = json.loads(meta_path.read_text()) if meta_path.exists() and encrypted.exists() else item.get('cipherChecksums', {}).get(object_id)
        if remote is None:
            self.uploads.report(plan_id, item, 'encrypting')
            if metadata and encrypted.exists():
                with encrypted.open('rb') as stream:
                    digest, composite = hash_stream(stream)
                if (encrypted.stat().st_size != expected_length or
                        base64.b64encode(bytes.fromhex(digest)).decode() != metadata['checksum'] or
                        composite != metadata['multipartSHA256']):
                    raise VaultError('integrity', '再開用の暗号化データが破損しています。', 409)
            else:
                metadata = self.encrypt(source, encrypted, object_id, key)
                if persistent:
                    atomic_json(meta_path, metadata)
            with self.uploads.lock:
                item.setdefault('cipherChecksums', {})[object_id] = metadata
                plan['stop'] = self.uploads.read(plan_id)['stop']
                self.uploads.save(plan)
            if metadata['byteSize'] != expected_length:
                raise VaultError('integrity', '暗号化データのサイズが一致しません。', 409)
            remote = self.uploads.send_file(client, plan, item, encrypted, object_key,
                metadata['checksum'], 'application/octet-stream', metadata['multipartSHA256'])
        if remote.get('ContentLength') != expected_length or not remote.get('ChecksumSHA256'):
            raise VaultError('integrity', 'S3暗号化ファイルのサイズ照合に失敗しました。', 409)
        if metadata and not remote_matches(remote, expected_length, metadata['checksum'], metadata['multipartSHA256']):
            raise VaultError('integrity', 'S3暗号化データの照合に失敗しました。', 409)
        encrypted.unlink(missing_ok=True)
        meta_path.unlink(missing_ok=True)
        return object_key

    @staticmethod
    def thumbnail(source, target, mime):
        from PIL import Image, ImageOps
        import warnings
        try:
            with warnings.catch_warnings():
                warnings.simplefilter('error', Image.DecompressionBombWarning)
                if mime.startswith('video/'):
                    ffmpeg = shutil.which('ffmpeg')
                    if not ffmpeg:
                        return False
                    result = subprocess.run([ffmpeg, '-v', 'error', '-i', str(source), '-frames:v', '1',
                        '-vf', 'scale=320:320:force_original_aspect_ratio=decrease', '-y', str(target)], capture_output=True, timeout=60)
                    if result.returncode:
                        return False
                    input_file = target
                elif mime == 'application/pdf':
                    from .pdf_preview import render_pdf
                    if not render_pdf(source, target):
                        return False
                    input_file = target
                elif mime.startswith('image/'):
                    input_file = source
                else:
                    return False
                with Image.open(input_file) as image:
                    preview = ImageOps.exif_transpose(image).convert('RGBA'); preview.info.clear(); preview.thumbnail((320, 320))
                    while True:
                        preview.save(target, format='PNG', optimize=True)
                        if target.stat().st_size <= 50000:
                            return True
                        preview.thumbnail((max(1, preview.width * 3 // 4), max(1, preview.height * 3 // 4)))
        except (OSError, ValueError, Image.DecompressionBombWarning, Image.DecompressionBombError, subprocess.TimeoutExpired):
            return False

    def upload(self, plan_id, key_id, key):
        plan = self.uploads.read(plan_id)
        try:
            client = self.uploads.client_factory(plan['bucket'], plan['profile'], plan['region']); client.verify_private()
            def work(item):
                if item['state'] == 'verified':
                    return
                if shutil.disk_usage(self.uploads.root).free < item['byteSize'] * 2 + 128 * 1024 ** 2:
                    raise VaultError('storage_error', '暗号化作業の空き容量が不足しています。', 507)
                with tempfile.TemporaryDirectory(dir=self.uploads.root, prefix='sealed-staging-') as temp:
                    source = Path(temp) / 'original'
                    self.uploads.snapshot(plan, item, source)
                    object_id = str(uuid.uuid5(uuid.UUID(plan_id), 'original:' + item['id']))
                    self.put(client, source, object_id, key_id, plan, item, key)
                    item['objectID'] = object_id
                    self.uploads.report(plan_id, item, 'thumbnail')
                    thumb = Path(temp) / 'preview.png'
                    if self.thumbnail(source, thumb, item['mimeType']):
                        thumb_id = str(uuid.uuid5(uuid.UUID(plan_id), 'thumbnail:' + item['id']))
                        self.put(client, thumb, thumb_id, key_id, plan, item, key)
                        item.update(thumbnailID=thumb_id, thumbnailBytes=thumb.stat().st_size)
            if not self.uploads.parallel_items(plan, work):
                plan['state'] = 'paused'
            else:
                self.uploads.live[plan_id] = {'phase': 'catalog', 'name': '', 'bytes': plan['byteSize'], 'totalBytes': plan['byteSize'], 'remainingSeconds': None, 'activeFiles': 0}
                manifest = {'schemaVersion': 1, 'id': plan_id, 'keyID': key_id, 'name': plan['name'], 'folders': plan['folders'],
                    'items': [{k: i.get(k) for k in ('id','name','folderId','byteSize','sha256','mimeType','objectID','thumbnailID','thumbnailBytes')} for i in plan['items']]}
                with tempfile.TemporaryDirectory(dir=self.uploads.root, prefix='sealed-staging-') as temp:
                    plain = Path(temp) / 'catalog.json'; atomic_json(plain, manifest)
                    if plain.stat().st_size > 4 * 1024 ** 2:
                        raise VaultError('too_large', 'フォルダを小さい単位へ分けてください。', 413)
                    catalog_key = f'media-hub/encrypted-catalogs/{key_id}/{plan_id}.bin'
                    remote = client.head(catalog_key)
                    if remote is None:
                        output = Path(temp) / 'catalog.sealed'; meta = self.encrypt(plain, output, plan_id, key)
                        client.put(output, catalog_key, meta['checksum'], 'application/octet-stream')
                        remote = client.head(catalog_key)
                        if not remote or remote.get('ChecksumSHA256') != meta['checksum'] or remote.get('ContentLength') != meta['byteSize']:
                            raise VaultError('integrity', '暗号化管理情報の照合に失敗しました。', 409)
                    if not remote:
                        raise VaultError('integrity', '暗号化管理情報を確認できません。', 409)
                plan['state'] = 'complete'
        except TransferPaused:
            plan['state'] = 'paused'
        except Exception as exc:
            plan['state'] = 'failed'; plan['error'] = exc.message if isinstance(exc, VaultError) else '暗号化送信に失敗しました。手動で再試行してください。'
        finally:
            with self.uploads.lock:
                plan['stop'] = self.uploads.read(plan_id)['stop']; self.uploads.save(plan); self.uploads.running.discard(plan_id); self.uploads.clear_progress(plan_id)
            key = None

    def library(self):
        # Ciphertext catalog names contain only random identifiers, never media names.
        results = []
        for public in self.list():
            raw = self.uploads.read(public['id'])
            if raw['state'] == 'complete':
                client = self.uploads.client_factory(raw['bucket'], raw['profile'], raw['region'])
                remote = client.head(f'media-hub/encrypted-catalogs/{raw["keyID"]}/{raw["id"]}.bin')
                if remote:
                    results.append({'id':raw['id'],'keyID':raw['keyID'],'cipherBytes':remote['ContentLength']})
        return results

    def url(self, key_id, plan_id, object_id=None):
        try:
            if str(uuid.UUID(key_id)) != key_id or (object_id and str(uuid.UUID(object_id)) != object_id):
                raise ValueError()
        except ValueError:
            raise VaultError('invalid_request', '暗号化ファイルの指定が不正です。')
        raw = self.uploads.read(plan_id)
        if raw['state'] != 'complete' or raw.get('keyID') != key_id:
            raise VaultError('not_found', '暗号化フォルダが見つかりません。', 404)
        if object_id and not any(object_id in (item.get('objectID'), item.get('thumbnailID')) for item in raw['items']):
            raise VaultError('not_found', '暗号化ファイルが見つかりません。', 404)
        key = f'media-hub/encrypted-objects/{key_id}/{plan_id}/{object_id}.bin' if object_id else f'media-hub/encrypted-catalogs/{key_id}/{plan_id}.bin'
        client = self.uploads.client_factory(raw['bucket'], raw['profile'], raw['region'])
        result = subprocess.run(['aws', '--profile',raw['profile'],'--region',raw['region'],'--no-cli-pager','s3','presign',f's3://{raw["bucket"]}/{key}','--expires-in','300'],capture_output=True,text=True,timeout=30)
        if result.returncode:
            # Reuse the CLI's sanitized authentication classification, never print the URL or stderr.
            client.head(key)
            raise VaultError('cloud_error', '暗号化ファイルの取得先を確認できません。', 502)
        return {'url': result.stdout.strip(), 'expiresIn': 300}
