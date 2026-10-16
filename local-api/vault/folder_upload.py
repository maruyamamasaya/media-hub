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
import time
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
import uuid
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'backend'))

from .service import VaultError
from catalog_limits import MAX_CATALOG_BYTES

GIB = 1024 ** 3
PDF_MAX_BYTES = 250 * 1024 ** 2
EXTENSIONS = {'.pdf', '.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.gif', '.tif', '.tiff', '.mp4', '.mov', '.m4v', '.webm', '.mkv'}


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


PART_SIZE = 16 * 1024 ** 2
MULTIPART_THRESHOLD = 64 * 1024 ** 2
SCAN_WORKERS = 4
UPLOAD_WORKERS = 4


def hash_stream(stream, target=None, progress=None):
    """One read supplies the whole digest and S3's composite SHA-256."""
    digest, parts, total = hashlib.sha256(), [], 0
    while chunk := stream.read(PART_SIZE):
        digest.update(chunk)
        parts.append(digest.copy().digest() if not parts else hashlib.sha256(chunk).digest())
        if target is not None:
            target.write(chunk)
        total += len(chunk)
        if progress:
            progress(total)
    composite = base64.b64encode(hashlib.sha256(b''.join(parts)).digest()).decode() + '-' + str(len(parts))
    return digest.hexdigest(), composite


def remote_matches(remote, length, digest, composite=None):
    return bool(remote and remote.get('ContentLength') == length and
                remote.get('ChecksumSHA256') in {digest, composite} - {None})


class TransferPaused(Exception):
    pass


from .multipart_upload import MultipartUpload


class S3CLI(MultipartUpload):
    def __init__(self, bucket, profile, region, recorder=None):
        self.bucket = bucket
        self.recorder = recorder
        self.timeout = 7200
        self.options = ['--profile', profile, '--region', region, '--no-cli-pager', '--output', 'json', '--cli-error-format', 'legacy']

    def call(self, operation, *args, missing=False):
        self.record(requests=1)
        result = subprocess.run(['aws', *self.options, 's3api', operation, '--bucket', self.bucket, *args], capture_output=True, text=True, timeout=self.timeout)
        if result.returncode:
            authentication_errors = ('your session has expired', 'please reauthenticate', 'expiredtoken',
                                     'unable to locate credentials', 'token has expired', 'sso session associated')
            if any(value in result.stderr.lower() for value in authentication_errors):
                raise VaultError('aws_login_required', 'AWSへの再ログインが必要です。ログイン後に接続を確認してください。', 401)
            if '(NoSuchUpload)' in result.stderr:
                raise VaultError('multipart_expired', '途中送信の期限が切れています。', 409)
            if missing and ('(404)' in result.stderr or '(NoSuchKey)' in result.stderr):
                return None
            raise VaultError('cloud_error', f'S3の{operation}に失敗しました。AWSログインと権限を確認して手動で再試行してください。', 502)
        value = json.loads(result.stdout) if result.stdout.strip() else {}
        # CLI response bodies are not wire metrics. Only downloaded object bytes are counted.
        self.record(received_bytes=value.get('ContentLength', 0) if operation == 'get-object' else 0)
        return value

    def record(self, **values):
        if self.recorder:
            try:
                self.recorder(**values)
            except (OSError, ValueError):
                # Statistics must not turn an otherwise completed media transfer into a failure.
                pass

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
                if item['Size'] > MAX_CATALOG_BYTES:
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
        from .upload_duplicates import CatalogCache
        self.duplicate_catalog_cache = CatalogCache()
        self.running = set()
        self.live = {}
        self.scan_jobs = {}
        self.scan_running = False
        self.queue = []
        # A prior crash may have interrupted response cleanup; no viewing files are durable.
        for prefix in ('staging-', 'viewing-', 'preview-build-', 'catalog-update-', 'sealed-staging-', 'duplicate-read-'):
            for directory in self.root.glob(prefix + '*'):
                if directory.is_dir() and not directory.is_symlink():
                    shutil.rmtree(directory)
        # Recover status only. Uploads never resume without a user action.
        for path in self.root.glob('*/plan.json'):
            plan = json.loads(path.read_text())
            if plan['state'] in ('uploading', 'queued'):
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
            'duplicateCount': plan.get('duplicateCount', 0),
        } | ({'completedAt': plan['completedAt']} if 'completedAt' in plan else {}) | ({'progress': dict(self.live[plan['id']])} if plan['id'] in self.live and
             plan['byteSize'] == self.live[plan['id']]['totalBytes'] else {})

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
            if plan['state'] == 'complete' and not self.read(plan['id']).get('noCatalog') and root not in seen:
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
            maximum_original = PDF_MAX_BYTES if item['mimeType'] == 'application/pdf' else 100 * 1024 ** 2
            if not thumbnail and item['byteSize'] > maximum_original:
                raise VaultError('too_large', 'PDFは250MiB、その他の原本は100MiBまで閲覧できます。', 413)
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

    def ensure_thumbnail(self, client, plan, item, snapshot=None):
        key = f'media-hub/thumbnails/{item["id"]}/{item["sha256"]}.png'
        remote = client.head(key)
        if remote is None:
            with tempfile.TemporaryDirectory(dir=self.root, prefix='preview-build-') as temp:
                output = Path(temp) / 'preview.png'
                source = Path(plan['sourceRoot']) / item['relativePath']
                try:
                    stream = snapshot.open('rb') if snapshot else self.open_source(Path(plan['sourceRoot']), source)
                except (OSError, VaultError):
                    # Backfill can use S3 if the original input no longer exists.
                    if item['byteSize'] > (PDF_MAX_BYTES if item['mimeType'] == 'application/pdf' else 100 * 1024 ** 2):
                        return False
                    source = Path(temp) / 'source'
                    client.download(item['objectKey'], item.get('versionId'), source)
                    stream = source.open('rb')
                with stream:
                    if not snapshot and hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
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
                            elif item['mimeType'] == 'application/pdf':
                                from .pdf_preview import render_pdf
                                if not render_pdf(f'/dev/fd/{stream.fileno()}', output, pass_fds=(stream.fileno(),)):
                                    return False
                                image_source = output
                            elif item['mimeType'].startswith('image/'):
                                image_source = stream
                            else:
                                return False
                            with Image.open(image_source) as image:
                                # JPEG decoder downsizing avoids expanding full-resolution pixels.
                                image.draft('RGB', (640, 640))
                                preview = ImageOps.exif_transpose(image).convert('RGBA')
                                preview.info.clear()
                                preview.thumbnail((320, 320))
                                while True:
                                    preview.save(output, format='PNG', optimize=True)
                                    if output.stat().st_size <= 50_000:
                                        break
                                    preview.thumbnail((max(1, preview.width * 3 // 4), max(1, preview.height * 3 // 4)))
                        stream.seek(0)
                        if not snapshot and hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
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
                if manifest_path.stat().st_size > MAX_CATALOG_BYTES:
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

    def check_catalog_capacity(self, plan):
        # Reserve the largest S3 VersionId (1,024 bytes) and all potential
        # thumbnails. Serialize exactly as atomic_json does, including UTF-8 names.
        sealed = getattr(self, 'sealed_catalog', False)
        items = []
        for item in plan['items']:
            entry = {k: item.get(k) for k in ('id', 'name', 'folderId', 'byteSize', 'sha256', 'mimeType')}
            if sealed:
                entry.update(objectID='0' * 36, thumbnailID='0' * 36, thumbnailBytes=50000)
            else:
                entry.update(objectKey=item['objectKey'], versionId='v' * 1024,
                             thumbnailKey=f'media-hub/thumbnails/{item["id"]}/{item["sha256"]}.png')
            items.append(entry)
        manifest = {'schemaVersion': 1, 'id': plan['id'], 'name': plan['name'],
                    'folders': plan['folders'], 'items': items}
        manifest['keyID' if sealed else 'rootId'] = plan.get('keyID', plan['rootId'])
        size = len(json.dumps(manifest, ensure_ascii=False).encode('utf-8'))
        if size > MAX_CATALOG_BYTES:
            raise VaultError('too_large', '送信後のフォルダ管理情報が16MiBを超える可能性があります。小さいフォルダ単位で確認し直してください。', 413)
        return size

    def scan(self, body, progress=None):
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
        items, candidates, skipped, total_bytes = [], [], 0, 0
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
                    if path.suffix.lower() == '.pdf' and before.st_size > PDF_MAX_BYTES:
                        raise VaultError('too_large', 'PDFは1ファイル250MiBまでです。', 413)
                    if before.st_size > 5 * GIB or not before.st_size:
                        raise VaultError('too_large', '初期版は1ファイル5GiB以下の空でないメディアに対応します。', 413)
                    total_bytes += before.st_size
                    if total_bytes > 20 * GIB:
                        raise VaultError('too_large', '初期版は1回20GiBまでです。小さい単位のフォルダを選んでください。', 413)
                candidates.append((path, signature(before)))
                if len(candidates) > 10000:
                    raise VaultError('too_large', '1回の確認は素材10,000件までです。', 413)
        read_bytes = 0
        if progress:
            progress(0, source_root.name, total_bytes)
        progress_lock = threading.Lock()
        def inspect(candidate):
            path, expected_signature = candidate
            reported = 0
            def report(amount):
                nonlocal read_bytes, reported
                with progress_lock:
                    read_bytes += amount - reported
                    reported = amount
                    if progress:
                        progress(read_bytes, path.name, total_bytes)
            with self.open_source(source_root, path) as stream:
                before = os.fstat(stream.fileno())
                if signature(before) != expected_signature:
                    raise VaultError('changed_file', '確認中に原本が変更されました。もう一度確認してください。', 409)
                digest, composite = hash_stream(stream,
                    progress=report)
                if signature(before) != signature(os.fstat(stream.fileno())):
                    raise VaultError('changed_file', '確認中に原本が変更されました。もう一度確認してください。', 409)
            relative = path.relative_to(source_root).as_posix()
            folder = path.parent.relative_to(source_root).as_posix()
            asset_id = str(uuid.uuid5(uuid.UUID(root_id), 'asset:' + relative))
            return {'id': asset_id, 'name': path.name, 'folderId': folder_id('' if folder == '.' else folder),
                          'relativePath': relative, 'byteSize': before.st_size, 'sha256': digest,
                          'multipartSHA256': composite, 'signature': signature(before), 'state': 'pending',
                          'objectKey': f'media-hub/originals/{asset_id}/{digest}',
                          'mimeType': mimetypes.guess_type(path.name)[0] or 'application/octet-stream'}
        # Preserve deterministic catalog order, while hashing independent files concurrently.
        with ThreadPoolExecutor(max_workers=SCAN_WORKERS) as executor:
            items = list(executor.map(inspect, candidates))
        plan = {'id': plan_id, 'rootId': root_id, 'name': source_root.name, 'sourceRoot': str(source_root),
                **{k: body[k] for k in ('bucket', 'profile', 'region')}, 'state': 'planned', 'error': '',
                'folders': folders, 'items': items, 'skipped': skipped, 'byteSize': sum(i['byteSize'] for i in items), 'stop': False}
        if plan['byteSize'] > 20 * GIB:
            raise VaultError('too_large', '初期版は1回20GiBまでです。小さい単位のフォルダを選んでください。', 413)
        self.check_catalog_capacity(plan)
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

    def begin_scan(self, body, scanner=None):
        with self.lock:
            if self.scan_running:
                raise VaultError('conflict', 'フォルダの確認完了を待ってください。', 409)
            self.scan_running = True
            job_id = str(uuid.uuid4())
            self.scan_jobs = {job_id: {'id': job_id, 'state': 'scanning', 'bytes': 0, 'totalBytes': 0, 'remainingSeconds': None, 'name': '', 'planId': None, 'error': ''}}
        def work():
            started = time.monotonic()
            def progress(amount, name, total):
                elapsed = time.monotonic() - started
                remaining = int((total - amount) * elapsed / amount) if amount and elapsed >= 3 else None
                with self.lock:
                    self.scan_jobs[job_id].update(bytes=amount, totalBytes=total, remainingSeconds=remaining, name=name)
            try:
                result = (scanner or self.scan)(body, progress=progress)
                with self.lock:
                    self.scan_jobs[job_id].update(state='complete', planId=result['id'])
            except Exception as exc:
                with self.lock:
                    self.scan_jobs[job_id].update(state='failed', error=exc.message if isinstance(exc, VaultError) else 'フォルダを確認できません。')
            finally:
                with self.lock:
                    self.scan_running = False
        threading.Thread(target=work, daemon=True).start()
        return self.scan_status(job_id)

    def scan_status(self, job_id):
        with self.lock:
            if job_id not in self.scan_jobs:
                raise VaultError('not_found', 'フォルダの確認記録がありません。', 404)
            return dict(self.scan_jobs[job_id])

    def snapshot(self, plan, item, target):
        with self.open_source(Path(plan['sourceRoot']), Path(plan['sourceRoot']) / item['relativePath']) as stream:
            if signature(os.fstat(stream.fileno())) != item['signature']:
                raise VaultError('changed_file', '確認後に原本が変更されました。送信を停止しました。', 409)
            with target.open('wb') as output:
                digest, composite = hash_stream(stream, output,
                    lambda n: self.report(plan['id'], item, 'preparing', n))
            if signature(os.fstat(stream.fileno())) != item['signature'] or digest != item['sha256']:
                raise VaultError('changed_file', '原本の照合に失敗しました。送信を停止しました。', 409)
        return composite

    def report(self, plan_id, item, phase, amount=0):
        with self.lock:
            live = self.live.setdefault(plan_id, {'phase': phase, 'name': '', 'bytes': 0, 'totalBytes': 0, 'remainingSeconds': None, 'activeFiles': 0})
            workers = getattr(self, '_progress_workers', {}).setdefault(plan_id, {})
            previous = workers.get(item['id'], ('', '', 0))[2]
            sent = amount if phase == 'uploading' else item['byteSize'] if phase == 'thumbnail' else 0
            workers[item['id']] = (phase, item['name'], max(previous, sent))
            live.update(phase=phase, name=item['name'], activeFiles=len(workers))
            # Count verified bytes and current transfer bytes; preparation is displayed separately.
            plan = self.read(plan_id)
            verified = sum(i['byteSize'] for i in plan['items'] if i['state'] == 'verified')
            active = sum(n for key, (p, _, n) in workers.items() if next(i for i in plan['items'] if i['id'] == key)['state'] != 'verified')
            live['bytes'] = min(plan['byteSize'], verified + active)
            live['totalBytes'] = plan['byteSize']
            elapsed = time.monotonic() - self._transfer_started.get(plan_id, time.monotonic())
            advanced = max(0, live['bytes'] - self._transfer_baseline.get(plan_id, 0))
            live['remainingSeconds'] = int((plan['byteSize'] - live['bytes']) * elapsed / advanced) if advanced and elapsed >= 3 else None

    def send_file(self, client, plan, item, source, key, digest, mime, composite=None):
        if source.stat().st_size >= MULTIPART_THRESHOLD and hasattr(client, 'put_resumable'):
            receipt = self.path(plan['id']).parent / 'transfers' / (hashlib.sha256(key.encode()).hexdigest() + '.json')
            client.put_resumable(source, key, digest, mime, receipt, PART_SIZE,
                lambda: self.stopped(plan['id']), lambda n: self.report(plan['id'], item, 'uploading', min(n, item['byteSize'])))
        else:
            self.report(plan['id'], item, 'uploading')
            client.put(source, key, digest, mime)
        remote = client.head(key)
        if not remote_matches(remote, source.stat().st_size, digest, composite):
            raise VaultError('integrity', 'S3のサイズ・SHA-256照合に失敗しました。', 409)
        return remote

    def parallel_items(self, plan, work):
        """Overlap small-file preparation, transfer and previews; bound large staging."""
        self._progress_workers = getattr(self, '_progress_workers', {})
        self._progress_workers[plan['id']] = {}
        self._transfer_started = getattr(self, '_transfer_started', {})
        self._transfer_baseline = getattr(self, '_transfer_baseline', {})
        self._transfer_started[plan['id']] = time.monotonic()
        self._transfer_baseline[plan['id']] = sum(i['byteSize'] for i in plan['items'] if i['state'] == 'verified')
        failed = threading.Event()
        def run(item):
            if failed.is_set() or self.stopped(plan['id']):
                return
            try:
                work(item)
                with self.lock:
                    item['state'] = 'verified'
                    plan['stop'] = self.read(plan['id'])['stop']
                    self.save(plan)
            except Exception:
                failed.set()
                raise
            finally:
                with self.lock:
                    workers = self._progress_workers[plan['id']]
                    workers.pop(item['id'], None)
                    live = self.live.get(plan['id'])
                    if live:
                        live['activeFiles'] = len(workers)
                        verified = sum(i['byteSize'] for i in plan['items'] if i['state'] == 'verified')
                        active = sum(n for key, (phase, _, n) in workers.items() if next(i for i in plan['items'] if i['id'] == key)['state'] != 'verified')
                        live['bytes'] = min(plan['byteSize'], verified + active)
                        if workers:
                            live['phase'], live['name'], _ = next(iter(workers.values()))
        for item in plan['items']:
            if item['state'] == 'verified':
                continue
            try:
                stream = self.open_source(Path(plan['sourceRoot']), Path(plan['sourceRoot']) / item['relativePath'])
            except FileNotFoundError:
                continue  # The item worker can reconcile an already uploaded object.
            with stream:
                if signature(os.fstat(stream.fileno())) != item['signature']:
                    raise VaultError('changed_file', '確認後に原本が変更されました。送信を停止しました。', 409)
        pending = []
        with ThreadPoolExecutor(max_workers=UPLOAD_WORKERS) as executor:
            for item in plan['items']:
                if failed.is_set() or self.stopped(plan['id']):
                    break
                if item['byteSize'] >= MULTIPART_THRESHOLD:
                    for future in pending:
                        future.result()
                    pending = []
                    if not failed.is_set() and not self.stopped(plan['id']):
                        run(item)
                else:
                    if len(pending) == UPLOAD_WORKERS:
                        done, _ = wait(pending, return_when=FIRST_COMPLETED)
                        for future in done:
                            future.result()
                            pending.remove(future)
                    if not failed.is_set() and not self.stopped(plan['id']):
                        pending.append(executor.submit(run, item))
            for future in pending:
                future.result()
        return not self.stopped(plan['id'])

    def clear_progress(self, plan_id):
        self.live.pop(plan_id, None)
        for field in ('_progress_workers', '_transfer_started', '_transfer_baseline'):
            getattr(self, field, {}).pop(plan_id, None)

    def start(self, plan_id, body):
        if set(body) != {'confirmUpload'} or body['confirmUpload'] is not True:
            raise VaultError('invalid_request', '送信内容を確認して開始してください。')
        with self.lock:
            plan = self.read(plan_id)
            if self.running:
                raise VaultError('conflict', '別の転送が実行中です。完了または停止後に開始してください。', 409)
            if plan.get('trash'):
                raise VaultError('conflict', 'ごみ箱を管理した履歴は新しく確認してください。', 409)
            if plan['state'] == 'complete':
                return self.public(plan)
            self.check_catalog_capacity(plan)
            plan.update(state='uploading', error='', stop=False)
            self.save(plan)
            self.running.add(plan_id)
            threading.Thread(target=self.upload, args=(plan_id,), daemon=True).start()
            return self.public(plan)

    def start_queue(self, plan_ids, body, uploader=None, validate=None):
        if (not isinstance(plan_ids, list) or not 1 <= len(plan_ids) <= 50 or
                any(not isinstance(i, str) for i in plan_ids) or len(set(plan_ids)) != len(plan_ids)):
            raise VaultError('invalid_request', '1回に50フォルダまで指定してください。')
        if set(body) != {'confirmUpload'} or body['confirmUpload'] is not True:
            raise VaultError('invalid_request', '送信内容を確認してください。')
        with self.lock:
            if self.running:
                raise VaultError('conflict', '実行中の送信完了または停止を待ってください。', 409)
            plans = [self.read(i) for i in plan_ids]
            for plan in plans:
                if plan['state'] == 'complete' or plan.get('trash'):
                    raise VaultError('conflict', '完了した履歴は予約できません。', 409)
                self.check_catalog_capacity(plan)
                if validate:
                    validate(plan)
            for plan in plans:
                plan.update(state='queued', stop=False, error='')
                self.save(plan)
            self.queue = list(plan_ids)
            self.running.update(plan_ids)
        def work():
            try:
                for plan_id in plan_ids:
                    with self.lock:
                        plan = self.read(plan_id)
                        if plan['stop']:
                            break
                        plan['state'] = 'uploading'
                        self.save(plan)
                    (uploader or self.upload)(plan_id)
                    if self.read(plan_id)['state'] != 'complete':
                        break
            finally:
                with self.lock:
                    for plan_id in plan_ids:
                        plan = self.read(plan_id)
                        if plan['state'] == 'queued':
                            plan.update(state='paused', stop=True)
                            self.save(plan)
                        self.running.discard(plan_id)
                    self.queue = []
        threading.Thread(target=work, daemon=True).start()
        return [self.public(p) for p in plans]

    def pause(self, plan_id):
        with self.lock:
            plan = self.read(plan_id)
            for queued_id in (self.queue if plan_id in self.queue else []):
                queued = self.read(queued_id)
                queued['stop'] = True
                self.save(queued)
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
            from .upload_duplicates import prepare
            prepare(self, plan, client)
            if plan.get('noCatalog'):
                plan['state'] = 'complete'; plan.setdefault('completedAt', time.time())
                return
            def work(item):
                expected = base64.b64encode(bytes.fromhex(item['sha256'])).decode()
                remote = client.head(item['objectKey'])
                if remote is None:
                    if shutil.disk_usage(self.root).free < item['byteSize'] + 128 * 1024 ** 2:
                        raise VaultError('storage_error', '送信用一時コピーの空き容量が不足しています。', 507)
                    with tempfile.TemporaryDirectory(dir=self.root, prefix='staging-') as directory:
                        snapshot = Path(directory) / 'original'
                        composite = self.snapshot(plan, item, snapshot)
                        with self.lock:
                            item['multipartSHA256'] = composite
                            plan['stop'] = self.read(plan_id)['stop']
                            self.save(plan)
                        remote = self.send_file(client, plan, item, snapshot, item['objectKey'], expected, item['mimeType'], composite)
                        item['versionId'] = remote.get('VersionId')
                        self.report(plan_id, item, 'thumbnail')
                        self.ensure_thumbnail(client, plan, item, snapshot)
                else:
                    if '-' in remote.get('ChecksumSHA256', '') and not item.get('multipartSHA256'):
                        # Old plans predate composite hashes. Reconcile our journal after a crash,
                        # or compute the same part boundaries from an unchanged local input.
                        receipt = self.path(plan_id).parent / 'transfers' / (hashlib.sha256(item['objectKey'].encode()).hexdigest() + '.json')
                        saved = json.loads(receipt.read_text()) if receipt.exists() else {}
                        scope = saved.get('scope', {})
                        if (scope.get('key') == item['objectKey'] and scope.get('bucket') == plan['bucket'] and
                                scope.get('digest') == expected and scope.get('size') == item['byteSize'] and
                                scope.get('partSize') == PART_SIZE and saved.get('composite')):
                            item['multipartSHA256'] = saved['composite']
                        else:
                            with tempfile.TemporaryDirectory(dir=self.root, prefix='staging-') as directory:
                                item['multipartSHA256'] = self.snapshot(plan, item, Path(directory) / 'original')
                    if not remote_matches(remote, item['byteSize'], expected, item.get('multipartSHA256')):
                        raise VaultError('integrity', 'S3原本のサイズ・SHA-256照合に失敗しました。', 409)
                    item['versionId'] = remote.get('VersionId')
                    self.report(plan_id, item, 'thumbnail')
                    self.ensure_thumbnail(client, plan, item)
            if not self.parallel_items(plan, work):
                plan['state'] = 'paused'
            else:
                self.live[plan_id] = {'phase': 'catalog', 'name': '', 'bytes': plan['byteSize'], 'totalBytes': plan['byteSize'], 'remainingSeconds': None, 'activeFiles': 0}
                # Immutable folder snapshot: filenames and parent IDs are metadata only.
                plan.setdefault('catalogCreatedAt', time.time())
                manifest = {'schemaVersion': 1, 'id': plan['id'], 'rootId': plan['rootId'], 'name': plan['name'], 'catalogCreatedAt': plan['catalogCreatedAt'],
                            'folders': plan['folders'], 'items': [{k: i.get(k) for k in
                                ('id', 'name', 'folderId', 'byteSize', 'sha256', 'objectKey', 'mimeType', 'versionId', 'thumbnailKey')} for i in plan['items']]}
                manifest_path = self.path(plan_id).parent / 'catalog.json'
                atomic_json(manifest_path, manifest)
                if manifest_path.stat().st_size > MAX_CATALOG_BYTES:
                    raise VaultError('too_large', 'フォルダ管理情報が大きすぎます。小さいフォルダ単位で送信してください。', 413)
                digest = base64.b64encode(hashlib.sha256(manifest_path.read_bytes()).digest()).decode()
                key = f'media-hub/catalogs/{plan["rootId"]}/{plan_id}.json'
                remote = client.head(key)
                if remote is None:
                    client.put(manifest_path, key, digest, 'application/json')
                    remote = client.head(key)
                if not remote or remote.get('ChecksumSHA256') != digest or remote.get('ContentLength') != manifest_path.stat().st_size:
                    raise VaultError('integrity', 'フォルダ管理情報の照合に失敗しました。', 409)
                plan['state'] = 'complete'; plan.setdefault('completedAt', time.time())
        except TransferPaused:
            plan['state'] = 'paused'
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
                    self.clear_progress(plan_id)
