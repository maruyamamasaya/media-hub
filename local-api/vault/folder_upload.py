"""Manual, copy-only folder uploads. No watchers or startup cloud operations."""
import base64
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import threading
import uuid

from .service import VaultError

GIB = 1024 ** 3
EXTENSIONS = {'.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.gif', '.tif', '.tiff', '.mp4', '.mov', '.m4v', '.webm', '.mkv'}


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.pending')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def signature(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns]


class S3CLI:
    def __init__(self, bucket, profile, region):
        self.bucket = bucket
        self.options = ['--profile', profile, '--region', region, '--no-cli-pager', '--output', 'json', '--cli-error-format', 'legacy']

    def call(self, operation, *args, missing=False):
        result = subprocess.run(['aws', *self.options, 's3api', operation, '--bucket', self.bucket, *args], capture_output=True, text=True, timeout=7200)
        if result.returncode:
            if missing and ('(404)' in result.stderr or '(NoSuchKey)' in result.stderr):
                return None
            raise VaultError('cloud_error', f'S3の{operation}に失敗しました。AWSログインと権限を確認して手動で再試行してください。', 502)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def verify_private(self):
        block = self.call('get-public-access-block')['PublicAccessBlockConfiguration']
        if not all(block.get(k) is True for k in ('BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets')):
            raise VaultError('cloud_security', '公開アクセスブロックの4項目が必要です。', 409)
        encryption = self.call('get-bucket-encryption')['ServerSideEncryptionConfiguration']['Rules']
        if not any(r['ApplyServerSideEncryptionByDefault']['SSEAlgorithm'] == 'AES256' for r in encryption):
            raise VaultError('cloud_security', 'SSE-S3暗号化の設定を確認してください。', 409)
        policy = json.loads(self.call('get-bucket-policy')['Policy'])
        if not any(s.get('Effect') == 'Deny' and s.get('Principal') == '*' and s.get('Action') == 's3:*'
                   and s.get('Condition', {}).get('Bool', {}).get('aws:SecureTransport') in (False, 'false')
                   and f'arn:aws:s3:::{self.bucket}/*' in s.get('Resource', []) for s in policy.get('Statement', [])):
            raise VaultError('cloud_security', 'TLS必須のバケットポリシーを確認してください。', 409)

    def head(self, key):
        return self.call('head-object', '--key', key, '--checksum-mode', 'ENABLED', missing=True)

    def put(self, path, key, digest, content_type, etag=None):
        condition = ['--if-match', etag] if etag else ['--if-none-match', '*']
        return self.call('put-object', '--key', key, '--body', str(path), '--checksum-algorithm', 'SHA256',
                         '--checksum-sha256', digest, '--content-type', content_type,
                         '--server-side-encryption', 'AES256', '--storage-class', 'STANDARD', *condition)

    def download(self, key, version, target):
        args = ['--key', key, '--checksum-mode', 'ENABLED']
        if version:
            args += ['--version-id', version]
        return self.call('get-object', *args, str(target))


class FolderUploads:
    def __init__(self, root, client_factory=S3CLI):
        self.root = Path(root) / 'folder-uploads'
        self.root.mkdir(parents=True, exist_ok=True)
        if os.name == 'posix':
            self.root.chmod(0o700)
        self.lock = threading.RLock()
        self.client_factory = client_factory
        self.running = set()
        # Recover status only. Uploads never resume without a user action.
        for path in self.root.glob('*/plan.json'):
            plan = json.loads(path.read_text())
            if plan['state'] == 'uploading':
                plan['state'] = 'interrupted'
                atomic_json(path, plan)

    def path(self, plan_id):
        try:
            if str(uuid.UUID(plan_id)) != plan_id:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise VaultError('invalid_request', '転送IDが不正です。')
        return self.root / plan_id / 'plan.json'

    def read(self, plan_id):
        path = self.path(plan_id)
        if not path.is_file():
            raise VaultError('not_found', '転送が見つかりません。', 404)
        return json.loads(path.read_text())

    def save(self, plan):
        atomic_json(self.path(plan['id']), plan)

    def public(self, plan):
        return {k: plan[k] for k in ('id', 'name', 'bucket', 'profile', 'region', 'state', 'byteSize', 'error')} | {
            'folders': [{k: folder[k] for k in ('id', 'name', 'parentId')} | {'isLocked': bool(folder.get('isLocked'))} for folder in plan['folders']],
            'items': [{k: item[k] for k in ('id', 'name', 'folderId', 'relativePath', 'byteSize', 'state')} for item in plan['items']],
            'completed': sum(i['state'] == 'verified' for i in plan['items']), 'skipped': plan['skipped'],
        }

    def list(self):
        with self.lock:
            return [self.public(json.loads(p.read_text())) for p in sorted(self.root.glob('*/plan.json'), key=lambda p: p.stat().st_mtime, reverse=True)]

    def library(self):
        # A newer uncommitted scan must not hide a successfully saved snapshot.
        saved, seen = [], set()
        for plan in self.list():
            root = next(f['id'] for f in plan['folders'] if f['parentId'] is None)
            if plan['state'] == 'complete' and root not in seen:
                saved.append(plan)
                seen.add(root)
        return saved

    def media(self, plan_id, item_id, thumbnail=False):
        with self.lock:
            plan = self.read(plan_id)
            item = next((i for i in plan['items'] if i['id'] == item_id), None)
            if plan['state'] != 'complete' or not item or item['state'] != 'verified':
                raise VaultError('not_found', '保存済みの素材が見つかりません。', 404)
            if not thumbnail and item['byteSize'] > 100 * 1024 ** 2:
                raise VaultError('too_large', '初期閲覧版は原本100MiBまでです。Macの元ファイルから開いてください。', 413)
            cache = self.root / 'view-cache'
            cache.mkdir(exist_ok=True)
            target = cache / (item['sha256'] + ('.thumbnail.png' if thumbnail else '.original'))
            if target.is_file():
                if thumbnail:
                    return target, 'image/png', item['name']
                with target.open('rb') as stream:
                    if hashlib.file_digest(stream, 'sha256').hexdigest() == item['sha256']:
                        return target, item['mimeType'], item['name']
                target.unlink()
            if not thumbnail:
                total = sum(p.stat().st_size for p in cache.glob('*.original'))
                if total + item['byteSize'] > 500 * 1024 ** 2:
                    raise VaultError('cache_full', '閲覧キャッシュが500MiBに達しました。自動削除はせず取得を停止しました。', 507)
                if shutil.disk_usage(cache).free < item['byteSize'] + 64 * 1024 ** 2:
                    raise VaultError('storage_error', '閲覧用コピーの空き容量が不足しています。', 507)
            if thumbnail:
                # Never fetch an original just to render the grid. Only use a verified viewing cache.
                original = cache / (item['sha256'] + '.original')
                if not item['mimeType'].startswith('image/') or not original.is_file() or original.stat().st_size > 100 * 1024 ** 2:
                    raise VaultError('no_preview', '素材を開いた後にプレビューを表示します。', 404)
                with original.open('rb') as stream:
                    if original.stat().st_size != item['byteSize'] or hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
                        raise VaultError('integrity', '閲覧キャッシュの照合に失敗しました。', 409)
                from PIL import Image, ImageOps
                import warnings
                pending = target.with_suffix('.pending')
                try:
                    with warnings.catch_warnings():
                        warnings.simplefilter('error', Image.DecompressionBombWarning)
                        with Image.open(original) as image:
                            image = ImageOps.exif_transpose(image)
                            image.thumbnail((320, 320))
                            image.convert('RGBA').save(pending, format='PNG')
                    if sum(p.stat().st_size for p in cache.glob('*.thumbnail.png')) + pending.stat().st_size > 64 * 1024 ** 2:
                        raise VaultError('cache_full', '小画像キャッシュが64MiBに達しました。', 507)
                    pending.replace(target)
                except VaultError:
                    raise
                except (OSError, ValueError, Image.DecompressionBombWarning, Image.DecompressionBombError):
                    raise VaultError('no_preview', 'この形式のプレビューは表示できません。', 404)
                finally:
                    pending.unlink(missing_ok=True)
                return target, 'image/png', item['name']
            client = self.client_factory(plan['bucket'], plan['profile'], plan['region'])
            try:
                client.download(item['objectKey'], item.get('versionId'), target.with_suffix('.pending'))
            except Exception:
                target.with_suffix('.pending').unlink(missing_ok=True)
                raise
            pending = target.with_suffix('.pending')
            try:
                with pending.open('rb') as downloaded:
                    valid = pending.stat().st_size == item['byteSize'] and hashlib.file_digest(downloaded, 'sha256').hexdigest() == item['sha256']
                if not valid:
                    raise VaultError('integrity', '原本のサイズ・SHA-256が一致しません。表示を停止しました。', 409)
                # Bound cache growth without deleting other files while being served.
                total = sum(p.stat().st_size for p in cache.glob('*.original'))
                if total + item['byteSize'] > 500 * 1024 ** 2:
                    raise VaultError('cache_full', '閲覧キャッシュが500MiBに達しました。自動削除はせず取得を停止しました。', 507)
                pending.replace(target)
            finally:
                pending.unlink(missing_ok=True)
            return target, item['mimeType'], item['name']

    def scan(self, body):
        if set(body) != {'path', 'bucket', 'profile', 'region'} or not all(isinstance(v, str) and v.strip() for v in body.values()):
            raise VaultError('invalid_request', 'フォルダとAWS接続先を指定してください。')
        import re
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', body['bucket']) or not re.fullmatch(r'[\w-]+', body['region']) or body['profile'].startswith('-'):
            raise VaultError('invalid_request', 'AWS接続先の指定が不正です。')
        supplied = Path(body['path']).expanduser()
        if not supplied.is_absolute() or supplied.is_symlink() or not supplied.is_dir():
            raise VaultError('invalid_request', '実在するフォルダの絶対パスを指定してください。')
        source_root = supplied.resolve()
        if source_root == Path(source_root.anchor) or source_root == Path.home():
            raise VaultError('invalid_request', 'メディア用フォルダを選んでください。')
        with self.lock:
            roots_path = self.root / 'roots.json'
            roots = json.loads(roots_path.read_text()) if roots_path.exists() else {}
            identity = hashlib.sha256(json.dumps([str(source_root), body['bucket'], body['region']]).encode()).hexdigest()
            root_id = roots.setdefault(identity, str(uuid.uuid4()))
            atomic_json(roots_path, roots)
        plan_id = str(uuid.uuid4())
        def folder_id(relative):
            return str(uuid.uuid5(uuid.UUID(root_id), 'folder:' + relative))
        folders = [{'id': folder_id(''), 'name': source_root.name, 'parentId': None}]
        items, skipped, total_bytes = [], 0, 0
        def walk_error(error):
            raise VaultError('unreadable_folder', '読み取れないフォルダがあります。権限を確認してください。', 409)
        for directory, dirs, files in os.walk(source_root, followlinks=False, onerror=walk_error):
            parent = Path(directory)
            dirs[:] = sorted(d for d in dirs if not d.startswith('.') and not (parent / d).is_symlink())
            for name in dirs:
                relative = (parent / name).relative_to(source_root).as_posix()
                parent_relative = parent.relative_to(source_root).as_posix()
                folders.append({'id': folder_id(relative), 'name': name, 'parentId': folder_id('' if parent_relative == '.' else parent_relative)})
            if len(folders) > 10000:
                raise VaultError('too_large', '1回の確認はフォルダ10,000件までです。', 413)
            for name in sorted(files):
                path = parent / name
                if name.startswith('.') or path.suffix.lower() not in EXTENSIONS or path.is_symlink():
                    skipped += 1
                    continue
                with self.open_source(source_root, path) as stream:
                    before = os.fstat(stream.fileno())
                    if before.st_size > 5 * GIB or not before.st_size:
                        raise VaultError('too_large', '初期版は1ファイル5GiB以下の空でないメディアに対応します。', 413)
                    total_bytes += before.st_size
                    if total_bytes > 20 * GIB:
                        raise VaultError('too_large', '初期版は1回20GiBまでです。小さい単位のフォルダを選んでください。', 413)
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                    if signature(before) != signature(os.fstat(stream.fileno())):
                        raise VaultError('changed_file', '確認中に原本が変更されました。もう一度確認してください。', 409)
                relative = path.relative_to(source_root).as_posix()
                folder = parent.relative_to(source_root).as_posix()
                asset_id = str(uuid.uuid5(uuid.UUID(root_id), 'asset:' + relative))
                items.append({'id': asset_id, 'name': name, 'folderId': folder_id('' if folder == '.' else folder),
                              'relativePath': relative, 'byteSize': before.st_size, 'sha256': digest,
                              'signature': signature(before), 'state': 'pending', 'objectKey': f'media-hub/originals/{asset_id}/{digest}',
                              'mimeType': mimetypes.guess_type(name)[0] or 'application/octet-stream'})
                if len(items) > 10000 or len(folders) > 10000:
                    raise VaultError('too_large', '1回の確認は素材・フォルダ各10,000件までです。', 413)
        plan = {'id': plan_id, 'rootId': root_id, 'name': source_root.name, 'sourceRoot': str(source_root),
                **{k: body[k] for k in ('bucket', 'profile', 'region')}, 'state': 'planned', 'error': '',
                'folders': folders, 'items': items, 'skipped': skipped, 'byteSize': sum(i['byteSize'] for i in items), 'stop': False}
        if plan['byteSize'] > 20 * GIB:
            raise VaultError('too_large', '初期版は1回20GiBまでです。小さい単位のフォルダを選んでください。', 413)
        with self.lock:
            self.save(plan)
        return self.public(plan)

    @staticmethod
    def open_source(root, path):
        if not path.is_relative_to(root):
            raise VaultError('changed_file', '選択フォルダ外のファイルは送信しません。', 409)
        if os.name == 'posix':
            # Open each directory without following links; keep parent descriptors
            # pinned so a concurrent rename cannot redirect the read outside the tree.
            parent_fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
            try:
                for component in path.parts[1:-1]:
                    next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
                    os.close(parent_fd)
                    parent_fd = next_fd
                fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
            finally:
                os.close(parent_fd)
        else:
            raise VaultError('unsupported_platform', 'このS3アップローダーはMac向けです。')
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise VaultError('changed_file', '通常ファイル以外は送信しません。', 409)
        return os.fdopen(fd, 'rb')

    def start(self, plan_id, body):
        if set(body) != {'confirmUpload'} or body['confirmUpload'] is not True:
            raise VaultError('invalid_request', '送信内容を確認して開始してください。')
        with self.lock:
            plan = self.read(plan_id)
            if self.running:
                raise VaultError('conflict', '別の転送が実行中です。完了または停止後に開始してください。', 409)
            if plan['state'] == 'complete':
                return self.public(plan)
            plan.update(state='uploading', error='', stop=False)
            self.save(plan)
            self.running.add(plan_id)
            threading.Thread(target=self.upload, args=(plan_id,), daemon=True).start()
            return self.public(plan)

    def pause(self, plan_id):
        with self.lock:
            plan = self.read(plan_id)
            plan['stop'] = True
            self.save(plan)
            return self.public(plan)

    def stopped(self, plan_id):
        with self.lock:
            return self.read(plan_id)['stop']

    def upload(self, plan_id):
        plan = self.read(plan_id)
        try:
            client = self.client_factory(plan['bucket'], plan['profile'], plan['region'])
            client.verify_private()
            for item in plan['items']:
                if self.stopped(plan_id):
                    plan['state'] = 'paused'
                    break
                expected = base64.b64encode(bytes.fromhex(item['sha256'])).decode()
                remote = client.head(item['objectKey'])
                if remote is None:
                    source = Path(plan['sourceRoot']) / item['relativePath']
                    if shutil.disk_usage(self.root).free < item['byteSize'] + 64 * 1024 ** 2:
                        raise VaultError('storage_error', '送信用一時コピーの空き容量が不足しています。', 507)
                    with tempfile.TemporaryDirectory(dir=self.root, prefix='staging-') as directory:
                        snapshot = Path(directory) / 'original'
                        with self.open_source(Path(plan['sourceRoot']), source) as stream:
                            if signature(os.fstat(stream.fileno())) != item['signature']:
                                raise VaultError('changed_file', '確認後に原本が変更されました。送信を停止しました。', 409)
                            with snapshot.open('wb') as target:
                                shutil.copyfileobj(stream, target)
                            if signature(os.fstat(stream.fileno())) != item['signature']:
                                raise VaultError('changed_file', '原本が変更されました。送信を停止しました。', 409)
                        with snapshot.open('rb') as stream:
                            if hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
                                raise VaultError('changed_file', '原本の照合に失敗しました。', 409)
                        client.put(snapshot, item['objectKey'], expected, item['mimeType'])
                    remote = client.head(item['objectKey'])
                if not remote or remote.get('ContentLength') != item['byteSize'] or remote.get('ChecksumSHA256') != expected:
                    raise VaultError('integrity', 'S3原本のサイズ・SHA-256照合に失敗しました。', 409)
                item['state'] = 'verified'
                item['versionId'] = remote.get('VersionId')
                with self.lock:
                    plan['stop'] = self.read(plan_id)['stop']
                    self.save(plan)
            else:
                if self.stopped(plan_id):
                    plan['state'] = 'paused'
                else:
                    # Immutable folder snapshot: filenames and parent IDs are metadata only.
                    manifest = {'schemaVersion': 1, 'id': plan['id'], 'rootId': plan['rootId'], 'name': plan['name'],
                                'folders': plan['folders'], 'items': [{k: i.get(k) for k in
                                    ('id', 'name', 'folderId', 'byteSize', 'sha256', 'objectKey', 'mimeType', 'versionId')} for i in plan['items']]}
                    manifest_path = self.path(plan_id).parent / 'catalog.json'
                    atomic_json(manifest_path, manifest)
                    digest = base64.b64encode(hashlib.sha256(manifest_path.read_bytes()).digest()).decode()
                    key = f'media-hub/catalogs/{plan["rootId"]}/{plan_id}.json'
                    remote = client.head(key)
                    if remote is None:
                        client.put(manifest_path, key, digest, 'application/json')
                        remote = client.head(key)
                    if not remote or remote.get('ChecksumSHA256') != digest or remote.get('ContentLength') != manifest_path.stat().st_size:
                        raise VaultError('integrity', 'フォルダ管理情報の照合に失敗しました。', 409)
                    plan['state'] = 'complete'
        except Exception as exc:
            plan['state'] = 'failed'
            plan['error'] = exc.message if isinstance(exc, VaultError) else '転送に失敗しました。AWS認証・原本・空き容量を確認して手動で再試行してください。'
        finally:
            with self.lock:
                try:
                    plan['stop'] = self.read(plan_id)['stop']
                    self.save(plan)
                finally:
                    self.running.discard(plan_id)
