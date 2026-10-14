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
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'backend'))

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
            authentication_errors = ('your session has expired', 'please reauthenticate', 'expiredtoken',
                                     'unable to locate credentials', 'token has expired', 'sso session associated')
            if any(value in result.stderr.lower() for value in authentication_errors):
                raise VaultError('aws_login_required', 'AWSへの再ログインが必要です。ログイン後に接続を確認してください。', 401)
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


    def require_unreferenced(self, keys, own_catalog):
        token = None
        while True:
            args = ['--prefix', 'media-hub/catalogs/']
            if token:
                args += ['--continuation-token', token]
            listing = self.call('list-objects-v2', *args)
            for item in listing.get('Contents', []):
                key = item['Key']
                if key == own_catalog:
                    continue
                if item['Size'] > 4 * 1024 ** 2:
                    raise VaultError('integrity', '別の一覧情報を確認できません。', 409)
                with tempfile.TemporaryDirectory(prefix='media-hub-reference-') as temp:
                    target = Path(temp) / 'catalog.json'
                    self.download(key, None, target)
                    value = json.loads(target.read_text())
                if not isinstance(value.get('items'), list):
                    raise VaultError('integrity', '別の一覧情報を確認できません。', 409)
                if any(i.get('objectKey') in keys or i.get('thumbnailKey') in keys for i in value['items']):
                    raise VaultError('shared_media', '別の送信履歴でも使われています。完全削除は停止しました。', 409)
            token = listing.get('NextContinuationToken')
            if not token:
                return

    def purge_versions(self, key):
        # Finish listing before deleting; an interrupted run lists remaining versions again.
        versions, key_marker, version_marker = [], None, None
        while True:
            args = ['--prefix', key]
            if key_marker:
                args += ['--key-marker', key_marker]
            if version_marker:
                args += ['--version-id-marker', version_marker]
            page = self.call('list-object-versions', *args)
            versions.extend(v['VersionId'] for field in ('Versions', 'DeleteMarkers') for v in page.get(field, []) if v['Key'] == key)
            if not page.get('IsTruncated'):
                break
            key_marker, version_marker = page['NextKeyMarker'], page.get('NextVersionIdMarker')
        for version in versions:
            self.call('delete-object', '--key', key, '--version-id', version)
        # Exact-key verification includes old versions and delete markers.
        remaining = self.call('list-object-versions', '--prefix', key)
        if any(v['Key'] == key for field in ('Versions', 'DeleteMarkers') for v in remaining.get(field, [])) or remaining.get('IsTruncated'):
            raise VaultError('cloud_error', '削除を確認できません。完全削除を再試行してください。', 502)


class FolderUploads:
    def __init__(self, root, client_factory=S3CLI):
        self.root = Path(root) / 'folder-uploads'
        self.root.mkdir(parents=True, exist_ok=True)
        if os.name == 'posix':
            self.root.chmod(0o700)
        self.lock = threading.RLock()
        self.client_factory = client_factory
        self.running = set()
        # A prior crash may have interrupted response cleanup; no viewing files are durable.
        for prefix in ('viewing-', 'preview-build-', 'catalog-update-', 'sealed-staging-'):
            for directory in self.root.glob(prefix + '*'):
                if directory.is_dir() and not directory.is_symlink():
                    shutil.rmtree(directory)
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

    def discard(self, plan_id):
        # Remove only an unstarted plan from the active list, retaining a local record.
        with self.lock:
            plan = self.read(plan_id)
            if plan['state'] != 'planned' or plan_id in self.running or any(i['state'] != 'pending' for i in plan['items']):
                raise VaultError('conflict', '取り消せるのは未送信の確認待ちだけです。', 409)
            archive = self.root / 'discarded'
            archive.mkdir(exist_ok=True)
            self.path(plan_id).parent.rename(archive / plan_id)
        return {'discarded': True}

    def library(self):
        # A newer uncommitted scan must not hide a successfully saved snapshot.
        saved, seen = [], set()
        for plan in sorted(self.list(), key=lambda p: self.read(p['id']).get('catalogCreatedAt', self.path(p['id']).stat().st_mtime), reverse=True):
            root = next(f['id'] for f in plan['folders'] if f['parentId'] is None)
            if plan['state'] == 'complete' and root not in seen:
                seen.add(root)
                raw = self.read(plan['id'])
                import catalog_trash
                active = catalog_trash.active(raw)
                if active is not None:
                    active['byteSize'] = sum(i['byteSize'] for i in active['items'])
                    saved.append(self.public(active))
        return saved

    def media(self, plan_id, item_id, thumbnail=False):
        """Normal viewer: S3-only reads with a response-lifetime temporary file."""
        with self.lock:
            plan = self.read(plan_id)
            item = next((i for i in plan['items'] if i['id'] == item_id), None)
            if any(item_id in e['itemIds'] for e in plan.get('trash', [])) or plan['state'] != 'complete' or not item or item['state'] != 'verified':
                raise VaultError('not_found', '保存済みの素材が見つかりません。', 404)
            key = item.get('thumbnailKey') if thumbnail else item['objectKey']
            if not key:
                raise VaultError('no_preview', 'サムネイルはまだありません。', 404)
            if not thumbnail and item['byteSize'] > 100 * 1024 ** 2:
                raise VaultError('too_large', '初期閲覧版は原本100MiBまでです。', 413)
            directory = Path(tempfile.mkdtemp(dir=self.root, prefix='viewing-'))
            target = directory / 'content'
            try:
                client = self.client_factory(plan['bucket'], plan['profile'], plan['region'])
                client.download(key, item.get('thumbnailVersionId') if thumbnail else item.get('versionId'), target)
                expected = item.get('thumbnailSHA256') if thumbnail else item['sha256']
                maximum = 50_000 if thumbnail else item['byteSize']
                if (not expected or target.stat().st_size > maximum or
                        (not thumbnail and target.stat().st_size != item['byteSize'])):
                    raise VaultError('integrity', '取得データのサイズを確認できません。', 409)
                with target.open('rb') as stream:
                    if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                        raise VaultError('integrity', '取得データの照合に失敗しました。', 409)
                return target, 'image/png' if thumbnail else item['mimeType'], item['name']
            except Exception:
                shutil.rmtree(directory)
                raise

    def release_media(self, path):
        directory = Path(path).parent
        if directory.parent == self.root and directory.name.startswith('viewing-'):
            shutil.rmtree(directory, ignore_errors=True)

    def ensure_thumbnail(self, client, plan, item):
        key = f'media-hub/thumbnails/{item["id"]}/{item["sha256"]}.png'
        remote = client.head(key)
        if remote is None:
            with tempfile.TemporaryDirectory(dir=self.root, prefix='preview-build-') as temp:
                output = Path(temp) / 'preview.png'
                source = Path(plan['sourceRoot']) / item['relativePath']
                try:
                    stream = self.open_source(Path(plan['sourceRoot']), source)
                except (OSError, VaultError):
                    # Backfill can use S3 if the original input no longer exists.
                    if item['byteSize'] > 100 * 1024 ** 2:
                        return False
                    source = Path(temp) / 'source'
                    client.download(item['objectKey'], item.get('versionId'), source)
                    stream = source.open('rb')
                with stream:
                    if hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
                        raise VaultError('changed_file', 'サムネイル作成元の原本が変わっています。', 409)
                    stream.seek(0)
                    from PIL import Image, ImageOps
                    import warnings
                    try:
                        with warnings.catch_warnings():
                            warnings.simplefilter('error', Image.DecompressionBombWarning)
                            if item['mimeType'].startswith('video/'):
                                ffmpeg = shutil.which('ffmpeg')
                                if not ffmpeg:
                                    return False
                                result = subprocess.run([ffmpeg, '-v', 'error', '-i', f'/dev/fd/{stream.fileno()}',
                                    '-frames:v', '1', '-vf', 'scale=320:320:force_original_aspect_ratio=decrease',
                                    '-y', str(output)], pass_fds=(stream.fileno(),), capture_output=True, timeout=60)
                                if result.returncode:
                                    return False
                                image_source = output
                            elif item['mimeType'].startswith('image/'):
                                image_source = stream
                            else:
                                return False
                            with Image.open(image_source) as image:
                                preview = ImageOps.exif_transpose(image).convert('RGBA')
                                preview.info.clear()
                                preview.thumbnail((320, 320))
                                while True:
                                    preview.save(output, format='PNG', optimize=True)
                                    if output.stat().st_size <= 50_000:
                                        break
                                    preview.thumbnail((max(1, preview.width * 3 // 4), max(1, preview.height * 3 // 4)))
                        stream.seek(0)
                        if hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
                            raise VaultError('changed_file', 'サムネイル作成中に原本が変わりました。', 409)
                    except (OSError, ValueError, Image.DecompressionBombWarning, Image.DecompressionBombError, subprocess.TimeoutExpired):
                        return False
                digest = base64.b64encode(hashlib.sha256(output.read_bytes()).digest()).decode()
                client.put(output, key, digest, 'image/png')
                remote = client.head(key)
                if not remote or remote.get('ChecksumSHA256') != digest or remote.get('ContentLength') != output.stat().st_size:
                    raise VaultError('integrity', 'サムネイルのS3照合に失敗しました。', 409)
        try:
            checksum = base64.b64decode(remote['ChecksumSHA256'], validate=True)
            if len(checksum) != 32 or not 0 < remote['ContentLength'] <= 50_000:
                raise ValueError()
        except (KeyError, ValueError, TypeError):
            raise VaultError('integrity', 'サムネイルのS3照合に失敗しました。', 409)
        item.update(thumbnailKey=key, thumbnailSHA256=checksum.hex(), thumbnailVersionId=remote.get('VersionId'))
        return True

    def publish_thumbnails(self, plan_id):
        """Explicit backfill: conditional catalog update, original objects never rewritten."""
        with self.lock:
            if self.running:
                raise VaultError('conflict', '送信完了後にサムネイルを作成してください。', 409)
            plan = self.read(plan_id)
            if plan['state'] != 'complete':
                raise VaultError('conflict', '保存済みフォルダだけが対象です。', 409)
            client = self.client_factory(plan['bucket'], plan['profile'], plan['region'])
            client.verify_private()
            key = f'media-hub/catalogs/{plan["rootId"]}/{plan_id}.json'
            remote = client.head(key)
            if not remote or not remote.get('ETag'):
                raise VaultError('integrity', '保存済みの管理情報を確認できません。', 409)
            count = 0
            for item in plan['items']:
                count += self.ensure_thumbnail(client, plan, item)
            with tempfile.TemporaryDirectory(dir=self.root, prefix='catalog-update-') as temp:
                manifest_path = Path(temp) / 'catalog.json'
                client.download(key, remote.get('VersionId'), manifest_path)
                manifest = json.loads(manifest_path.read_text())
                if manifest.get('id') != plan_id or manifest.get('rootId') != plan['rootId']:
                    raise VaultError('integrity', '管理情報のフォルダが一致しません。', 409)
                by_id = {item['id']: item for item in plan['items']}
                for entry in manifest['items']:
                    item = by_id[entry['id']]
                    if entry['sha256'] != item['sha256'] or entry['objectKey'] != item['objectKey']:
                        raise VaultError('integrity', '管理情報の原本が一致しません。', 409)
                    for field in ('thumbnailKey',):
                        if field in item:
                            entry[field] = item[field]
                original_bytes = manifest_path.read_bytes()
                atomic_json(manifest_path, manifest)
                if manifest_path.stat().st_size > 4 * 1024 ** 2:
                    raise VaultError('too_large', 'フォルダ管理情報が大きすぎます。小さいフォルダ単位で送信してください。', 413)
                # Avoid unnecessary version creation on repeated backfills.
                if json.loads(original_bytes) != manifest:
                    digest = base64.b64encode(hashlib.sha256(manifest_path.read_bytes()).digest()).decode()
                    client.put(manifest_path, key, digest, 'application/json', etag=remote['ETag'])
                    verified = client.head(key)
                    if not verified or verified.get('ChecksumSHA256') != digest:
                        raise VaultError('integrity', '管理情報のS3照合に失敗しました。', 409)
                atomic_json(self.path(plan_id).parent / 'catalog.json', manifest)
            self.save(plan)
            return {'thumbnails': count, 'items': len(plan['items'])}

    def purge_legacy_view_cache(self):
        """Remove only identifiable viewer copies, never inputs or upload staging."""
        cache = self.root / 'view-cache'
        if not cache.is_dir() or cache.is_symlink():
            return 0
        hashes = {i['sha256'] for p in self.list() if p['state'] == 'complete'
                  for i in self.read(p['id'])['items'] if i['state'] == 'verified'}
        removed = 0
        for path in cache.iterdir():
            if not path.is_file() or path.is_symlink():
                continue
            sha = path.name.split('.')[0]
            if sha not in hashes:
                continue
            if path.name == sha + '.original':
                with path.open('rb') as stream:
                    if hashlib.file_digest(stream, 'sha256').hexdigest() != sha:
                        continue
            elif path.name != sha + '.thumbnail.png':
                continue
            path.unlink()
            removed += 1
        return removed

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
        if self.read(plan_id).get('trash'):
            raise VaultError('conflict', 'ごみ箱を管理した送信記録は再送信できません。新しく確認してください。', 409)
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
                self.ensure_thumbnail(client, plan, item)
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
                                    ('id', 'name', 'folderId', 'byteSize', 'sha256', 'objectKey', 'mimeType', 'versionId', 'thumbnailKey')} for i in plan['items']]}
                    manifest_path = self.path(plan_id).parent / 'catalog.json'
                    atomic_json(manifest_path, manifest)
                    if manifest_path.stat().st_size > 4 * 1024 ** 2:
                        raise VaultError('too_large', 'フォルダ管理情報が大きすぎます。小さいフォルダ単位で送信してください。', 413)
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
