import base64
import hashlib
import json
import threading
import uuid
import warnings
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError
from .repository import AssetRepository
from .storage import AssetStorage, checksum

MAX_BYTES = 100 * 1024 * 1024
LIBRARY_ID = 'local-library'
VIDEO_MIMES = {'.mp4': 'video/mp4', '.mov': 'video/quicktime', '.webm': 'video/webm', '.mkv': 'video/x-matroska', '.avi': 'video/x-msvideo', '.m4v': 'video/mp4'}
MIMES = {'JPEG': 'image/jpeg', 'PNG': 'image/png', 'WEBP': 'image/webp'}


def identifier():
    return str(uuid.uuid4())


def now():
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


class VaultError(Exception):
    def __init__(self, code, message, status=400):
        self.code, self.message, self.status = code, message, status


class Vault:
    def __init__(self, root, fixtures):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.storage = AssetStorage(self.root / 'objects')
        self.local_directory = self.storage.path('local-originals')
        self.local_directory.mkdir(parents=True, exist_ok=True)
        self.staging = AssetStorage(self.root / 'staging')
        self.repo = AssetRepository(self.root / 'library.sqlite3')
        with self.repo.connect() as db:
            self.storage.reference_roots = {r['id']: Path(r['path']) for r in db.execute('SELECT * FROM storage_roots')}
        self.fixtures = Path(fixtures).resolve()
        self.lock = threading.RLock()
        self.recover()

    def asset(self, asset_id):
        result = self.repo.asset(asset_id)
        if result is None:
            raise VaultError('not_found', '素材が見つかりません。', 404)
        for f in result['files']:
            try:
                exists = self.storage.path(f['objectKey']).is_file()
            except (ValueError, OSError, KeyError):
                exists = False
            if f['state'] == 'ready' and not exists:
                f['state'], f['error'] = 'missing', '保存ファイルが見つかりません。'
            if f['role'] == 'original' and result['originalOwnership'] == 'reference' and f['state'] == 'ready':
                with self.repo.connect() as db:
                    modified = db.execute('SELECT originalModifiedNs FROM assets WHERE id=?', (asset_id,)).fetchone()[0]
                stat = self.storage.path(f['objectKey']).stat()
                if stat.st_size != f['byteSize'] or stat.st_mtime_ns != modified:
                    if stat.st_size == f['byteSize'] and checksum(self.storage.path(f['objectKey'])) == f['sha256']:
                        with self.repo.connect() as db:
                            db.execute('UPDATE assets SET originalModifiedNs=? WHERE id=?', (stat.st_mtime_ns, asset_id))
                    else:
                        f['state'], f['error'] = 'changed', 'フォルダ内で原本が変更されています。登録時の状態へ戻すか、別名で新しい素材として追加してください。'
        return result

    def job(self, job_id):
        with self.repo.connect() as db:
            if not db.execute('SELECT 1 FROM jobs WHERE id=?', (job_id,)).fetchone():
                raise VaultError('not_found', '追加処理が見つかりません。', 404)
            items = [dict(row) for row in db.execute('SELECT id,filename,state,assetId,code,message FROM import_items WHERE jobId=? ORDER BY rowid', (job_id,))]
        return {'id': job_id, 'items': items}

    def new_job(self):
        job_id = identifier()
        with self.repo.connect() as db:
            db.execute('INSERT INTO jobs VALUES (?,?)', (job_id, now()))
        return job_id

    def add_stream(self, job_id, filename, stream, reference_key=None):
        with self.lock:
            item_id = identifier()
            # Both Windows and POSIX supplied paths are reduced to a display basename.
            filename = filename.replace('\\', '/').split('/')[-1][:255] or 'image'
            with self.repo.connect() as db:
                db.execute('INSERT INTO import_items(id,jobId,filename,state,stageKey) VALUES (?,?,?,?,?)', (item_id, job_id, filename, 'staging', item_id))
                db.execute('UPDATE import_items SET referenceKey=? WHERE id=?', (reference_key, item_id))
            try:
                with self.staging.path(item_id).open('wb') as target:
                    size = 0
                    while chunk := stream.read(1024 * 1024):
                        size += len(chunk)
                        if size > MAX_BYTES:
                            raise VaultError('too_large', '1ファイルの上限は100MBです。', 413)
                        target.write(chunk)
                with self.repo.connect() as db:
                    db.execute("UPDATE import_items SET state='processing' WHERE id=?", (item_id,))
                self.process_item(item_id)
            except (OSError, VaultError) as exc:
                self.fail(item_id, exc)
                if isinstance(exc, VaultError) and exc.code == 'too_large':
                    self.staging.delete(item_id)

    def fail(self, item_id, exc):
        code = exc.code if isinstance(exc, VaultError) else 'storage_error'
        message = exc.message if isinstance(exc, VaultError) else '保存に失敗しました。空き容量を確認して再試行してください。'
        with self.repo.connect() as db:
            db.execute("UPDATE import_items SET state='failed',code=?,message=? WHERE id=?", (code, message, item_id))

    def inspect(self, path, filename):
        if not path.stat().st_size:
            raise VaultError('corrupt', '空のファイルです。')
        suffix = Path(filename).suffix.lower()
        if suffix in VIDEO_MIMES:
            width = height = None
            probe = shutil.which('ffprobe')
            if probe:
                try:
                    result = subprocess.run([probe, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'json', str(path)], capture_output=True, check=True, timeout=15)
                    stream = json.loads(result.stdout)['streams'][0]
                    width, height = int(stream['width']), int(stream['height'])
                except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError):
                    pass  # An unreadable/unsupported video is still retained as an original.
            return VIDEO_MIMES[suffix], width, height
        try:
            with warnings.catch_warnings():
                warnings.simplefilter('error', Image.DecompressionBombWarning)
                with Image.open(path) as image:
                    if image.format not in MIMES:
                        raise VaultError('unsupported', 'JPEG・PNG・WebP・HEICを追加できます。')
                    mime, width, height = MIMES[image.format], image.width, image.height
                    image.verify()
                # verify alone does not fully decode compressed pixels.
                with Image.open(path) as image:
                    image.load()
            return mime, width, height
        except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError, Image.DecompressionBombWarning):
            # Recognise HEIF brands; no claim that an unavailable decoder verified pixels.
            header = path.read_bytes()[:32] if path.stat().st_size < 1024 else self.read_header(path)
            if filename.lower().endswith(('.heic', '.heif')) and header[4:8] == b'ftyp' and header[8:12] in (b'heic', b'heix', b'hevc', b'mif1'):
                return 'image/heic', None, None
            raise VaultError('corrupt', '画像を読み込めません。形式または破損を確認してください。')

    @staticmethod
    def read_header(path):
        with path.open('rb') as stream:
            return stream.read(32)

    def process_item(self, item_id):
        with self.lock:
            with self.repo.connect() as db:
                item = dict(db.execute('SELECT * FROM import_items WHERE id=?', (item_id,)).fetchone())
            path = self.staging.path(item['stageKey'])
            try:
                if not path.is_file():
                    raise VaultError('interrupted', '追加が中断しました。ファイルをもう一度選択してください。')
                mime, width, height = self.inspect(path, item['filename'])
                sha = checksum(path)
                with self.repo.connect() as db:
                    existing = db.execute('SELECT a.id,a.trashedAt FROM assets a JOIN files f ON a.id=f.assetId WHERE f.role=\'original\' AND f.sha256=?', (sha,)).fetchone()
                    if existing:
                        db.execute("UPDATE import_items SET state='duplicate',assetId=?,code=?,message=? WHERE id=?", (existing['id'], 'trashed_duplicate' if existing['trashedAt'] else 'duplicate', 'ごみ箱に同じ素材があります。復元できます。' if existing['trashedAt'] else '登録済みの素材です。', item_id))
                        self.staging.delete(item['stageKey'])
                        return
                asset_id, file_id = item['assetId'] or identifier(), item_id
                with self.repo.connect() as db:
                    db.execute('UPDATE import_items SET assetId=? WHERE id=?', (asset_id, item_id))
                # Ordinary files remain accessible from Explorer/Finder. Folder scans reference
                # the source; picker uploads retain the existing managed-copy behavior.
                suffix = Path(item['filename']).suffix.lower()
                safe_stem = ''.join(c if c.isalnum() or c in '-_ ' else '_' for c in Path(item['filename']).stem)[:100] or 'image'
                key = item['referenceKey'] or f'local-originals/{safe_stem}-{file_id[:8]}{suffix}'
                if not item['referenceKey']:
                    self.storage.put(path, key)
                if checksum(self.storage.path(key)) != sha:
                    raise VaultError('integrity', '原本の照合に失敗しました。')
                timestamp = now()
                with self.repo.connect() as db:
                    db.execute('INSERT INTO assets(id,libraryId,kind,name,createdAt,updatedAt,originalExtension) VALUES (?,?,?,?,?,?,?)', (asset_id, LIBRARY_ID, 'video' if mime.startswith('video/') else 'image', Path(item['filename']).stem, timestamp, timestamp, Path(item['filename']).suffix.lower().lstrip('.')))
                    db.execute('INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', (file_id, asset_id, 'original', item['filename'], key, mime, path.stat().st_size, sha, width, height, 'ready', None))
                    db.execute("UPDATE assets SET storageLocation='local',originalOwnership=?,originalModifiedNs=? WHERE id=?", ('reference' if item['referenceKey'] else 'managed', self.storage.path(key).stat().st_mtime_ns, asset_id))
                    db.execute("UPDATE import_items SET state='ready',code=NULL,message='追加しました。' WHERE id=?", (item_id,))
                self.staging.delete(item['stageKey'])
                self.preview(asset_id)
            except (OSError, VaultError) as exc:
                self.fail(item_id, exc)

    def preview(self, asset_id):
        asset = self.asset(asset_id)
        original = next(f for f in asset['files'] if f['role'] == 'original')
        if original['state'] != 'ready':
            raise VaultError('missing_file', original['error'] or '原本が見つかりません。', 409)
        if original['mimeType'].startswith('video/'):
            return self.video_preview(asset, original)
        for role, dimension in [('thumbnail', 512), ('display', 2048)]:
            with self.repo.connect() as db:
                previous = db.execute('SELECT id,objectKey FROM files WHERE assetId=? AND role=?', (asset_id, role)).fetchone()
            file_id = previous['id'] if previous else identifier()
            key = previous['objectKey'] if previous else f'libraries/{LIBRARY_ID}/assets/{asset_id}/files/{file_id}'
            target = self.staging.path(f'{file_id}.jpg')
            try:
                with Image.open(self.storage.path(original['objectKey'])) as image:
                    image = ImageOps.exif_transpose(image)
                    image.thumbnail((dimension, dimension))
                    transparent = image.mode in ('RGBA', 'LA') or 'transparency' in image.info
                    image = image.convert('RGBA' if transparent else 'RGB')
                    image_format, extension, preview_mime = ('PNG', 'png', 'image/png') if transparent else ('JPEG', 'jpg', 'image/jpeg')
                    image.save(target, image_format, **({} if transparent else {'quality': 85}))
                    width, height = image.size
                self.storage.put(target, key)
                info = (file_id, asset_id, role, f'{role}.{extension}', key, preview_mime, target.stat().st_size, checksum(target), width, height, 'ready', None)
            except (OSError, ValueError, UnidentifiedImageError):
                info = (file_id, asset_id, role, f'{role}.jpg', key, 'image/jpeg', 0, '', None, None, 'failed', 'プレビューを生成できません。原本は保管されています。')
            finally:
                target.unlink(missing_ok=True)
            with self.repo.connect() as db:
                db.execute('INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', info)
        return self.asset(asset_id)

    def video_preview(self, asset, original):
        # Each derived file has its own ID; conversion never writes to the original.
        executable = shutil.which('ffmpeg')
        for role, suffix, mime in [('thumbnail', 'jpg', 'image/jpeg'), ('display', 'mp4', 'video/mp4')]:
            with self.repo.connect() as db:
                previous = db.execute('SELECT id,objectKey FROM files WHERE assetId=? AND role=?', (asset['id'], role)).fetchone()
            file_id = previous['id'] if previous else identifier()
            key = previous['objectKey'] if previous else f"libraries/{LIBRARY_ID}/assets/{asset['id']}/files/{file_id}"
            target = self.staging.path(f'{file_id}.{suffix}')
            width = height = None
            try:
                if not executable:
                    raise ValueError('FFmpegが未導入のため閲覧用動画を生成できません。原本は保管されています。')
                command = [executable, '-nostdin', '-v', 'error', '-y', '-i', str(self.storage.path(original['objectKey']))]
                if role == 'thumbnail':
                    command += ['-frames:v', '1', '-vf', 'scale=512:512:force_original_aspect_ratio=decrease']
                else:
                    command += ['-map', '0:v:0', '-map', '0:a:0?', '-vf', "scale=1280:1280:force_original_aspect_ratio=decrease:force_divisible_by=2", '-c:v', 'libx264', '-preset', 'fast', '-crf', '28', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart']
                subprocess.run(command + [str(target)], check=True, timeout=180, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if role == 'thumbnail':
                    with Image.open(target) as image:
                        width, height = image.size
                self.storage.put(target, key)
                info = (file_id, asset['id'], role, f'{role}.{suffix}', key, mime, target.stat().st_size, checksum(target), width, height, 'ready', None)
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                message = str(exc) if isinstance(exc, ValueError) else '動画の変換に失敗しました。原本は保管されています。'
                info = (file_id, asset['id'], role, f'{role}.{suffix}', key, mime, 0, '', None, None, 'failed', message)
            finally:
                target.unlink(missing_ok=True)
            with self.repo.connect() as db:
                db.execute('INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', info)
        return self.asset(asset['id'])

    def recover(self):
        with self.lock:
            with self.repo.connect() as db:
                items = [dict(r) for r in db.execute("SELECT * FROM import_items WHERE state IN ('staging','processing')")]
                deleting = [r['id'] for r in db.execute("SELECT id FROM assets WHERE state='deleting'")]
            for item in items:
                if item['assetId'] and self.repo.asset(item['assetId']):
                    with self.repo.connect() as db:
                        db.execute("UPDATE import_items SET state='ready',code=NULL,message='追加しました。' WHERE id=?", (item['id'],))
                    self.staging.delete(item['stageKey'])
                    if next(f for f in self.asset(item['assetId'])['files'] if f['role'] == 'original')['state'] == 'ready':
                        self.preview(item['assetId'])
                elif item['state'] == 'processing':
                    self.process_item(item['id'])
                else:
                    self.fail(item['id'], VaultError('interrupted', '追加が中断しました。ファイルをもう一度選択してください。'))
            for asset_id in deleting:
                try:
                    self.finish_delete(asset_id)
                except OSError:
                    pass  # Keep deleting for an explicit retry.

    def retry_job(self, job_id):
        with self.lock:
            self.job(job_id)
            with self.repo.connect() as db:
                ids = [r['id'] for r in db.execute("SELECT id FROM import_items WHERE jobId=? AND state='failed' AND code='storage_error'", (job_id,))]
            for item_id in ids:
                with self.repo.connect() as db:
                    db.execute("UPDATE import_items SET state='processing' WHERE id=?", (item_id,))
                self.process_item(item_id)
            return self.job(job_id)

    def fixture_import(self):
        job_id = self.new_job()
        if self.fixtures.is_dir():
            for path in sorted(self.fixtures.iterdir()):
                if path.is_file() and path.resolve().is_relative_to(self.fixtures) and not path.is_symlink():
                    with path.open('rb') as stream:
                        self.add_stream(job_id, path.name, stream)
        return self.job(job_id)

    def storage_roots(self):
        with self.repo.connect() as db:
            rows = [dict(r) for r in db.execute('SELECT * FROM storage_roots ORDER BY path')]
        for row in rows:
            row['state'] = 'ready' if Path(row['path']).is_dir() else 'missing'
        return rows

    def sync_directory(self, body):
        if set(body) != {'path', 'rootId'} or not isinstance(body['path'], str) or not body['path'].strip() or (body['rootId'] is not None and not isinstance(body['rootId'], str)):
            raise VaultError('invalid_request', '同期フォルダを指定してください。')
        if not Path(body['path']).expanduser().is_absolute():
            raise VaultError('invalid_request', 'フォルダの絶対パスを指定してください。')
        folder = Path(body['path']).expanduser().resolve()
        if not folder.is_dir():
            raise VaultError('folder_missing', '指定フォルダが見つかりません。移動・削除・ドライブの接続を確認してください。', 404)
        if folder == self.root or folder.is_relative_to(self.root) or self.root.is_relative_to(folder):
            raise VaultError('invalid_request', 'アプリのデータ領域と重なるフォルダは外部同期に指定できません。')
        with self.lock:
            with self.repo.connect() as db:
                existing = db.execute('SELECT id FROM storage_roots WHERE path=?', (str(folder),)).fetchone()
                if body['rootId']:
                    if not db.execute('SELECT 1 FROM storage_roots WHERE id=?', (body['rootId'],)).fetchone():
                        raise VaultError('not_found', '登録フォルダが見つかりません。', 404)
                    if existing and existing['id'] != body['rootId']:
                        raise VaultError('conflict', 'そのフォルダは別の登録先として使用中です。', 409)
                    root_id = body['rootId']
                    db.execute('UPDATE storage_roots SET path=? WHERE id=?', (str(folder), root_id))
                    if not existing:
                        db.execute("UPDATE assets SET originalModifiedNs=NULL WHERE id IN (SELECT assetId FROM files WHERE role='original' AND objectKey LIKE ?)", (f'references/{root_id}/%',))
                else:
                    root_id = existing['id'] if existing else identifier()
                    db.execute('INSERT OR IGNORE INTO storage_roots(id,path) VALUES (?,?)', (root_id, str(folder)))
                old_sources = {r['relativePath']: dict(r) for r in db.execute('SELECT * FROM local_sources WHERE rootId=?', (root_id,))}
            self.storage.reference_roots[root_id] = folder
            result = {'rootId': root_id, 'added': 0, 'matched': 0, 'moved': 0, 'changed': 0, 'missing': 0, 'failed': 0, 'limited': False}
            observed = set()
            relocated = set()
            candidates = 0
            for path in folder.rglob('*'):
                if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(folder) or path.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.webp', '.heic', '.heif', *VIDEO_MIMES):
                    continue
                relative = path.relative_to(folder).as_posix()
                observed.add(relative)
                if path.stat().st_size > MAX_BYTES:
                    result['failed'] += 1
                    continue
                sha = checksum(path)
                if relative in old_sources and sha != old_sources[relative]['sha256']:
                    result['changed'] += 1
                    continue
                if relative in old_sources:
                    with self.repo.connect() as db:
                        canonical = db.execute("SELECT objectKey FROM files WHERE assetId=? AND role='original'", (old_sources[relative]['assetId'],)).fetchone()
                    if canonical and self.storage.path(canonical['objectKey']).is_file():
                        result['matched'] += 1
                        continue
                if candidates >= 100:
                    result['limited'] = True
                    continue
                candidates += 1
                key = f'references/{root_id}/{relative}'
                job = self.new_job()
                with path.open('rb') as stream:
                    self.add_stream(job, path.name, stream, key)
                item = self.job(job)['items'][0]
                if item['state'] not in ('ready', 'duplicate'):
                    result['failed'] += 1
                    continue
                asset_id = item['assetId']
                if checksum(path) != sha:
                    result['changed'] += 1
                    continue
                with self.repo.connect() as db:
                    original = db.execute("SELECT * FROM files WHERE assetId=? AND role='original'", (asset_id,)).fetchone()
                    asset = db.execute('SELECT * FROM assets WHERE id=?', (asset_id,)).fetchone()
                    # Never revive trash or replace a different valid local copy.
                    replace = not asset['trashedAt'] and not db.execute('SELECT 1 FROM transfer_cleanup WHERE assetId=?', (asset_id,)).fetchone() and (asset['storageLocation'] == 'development-remote' or original['objectKey'] == key or not self.storage.path(original['objectKey']).is_file())
                    if replace and original['objectKey'] != key:
                        prefix = f'references/{root_id}/'
                        if original['objectKey'].startswith(prefix):
                            old_relative = original['objectKey'][len(prefix):]
                            relocated.add(old_relative)
                            db.execute('DELETE FROM local_sources WHERE rootId=? AND relativePath=?', (root_id, old_relative))
                            result['moved'] += 1
                        db.execute('UPDATE files SET objectKey=?,originalFilename=? WHERE id=?', (key, path.name, original['id']))
                        db.execute("UPDATE assets SET storageLocation='local',archivedAt=NULL,originalOwnership='reference',originalModifiedNs=?,revision=revision+1,updatedAt=? WHERE id=?", (path.stat().st_mtime_ns, now(), asset_id))
                    db.execute('INSERT OR REPLACE INTO local_sources VALUES (?,?,?,?)', (root_id, relative, asset_id, sha))
                result['added' if item['state'] == 'ready' else 'matched'] += 1
            # Missing paths are reported, never automatically deleted or trashed.
            result['missing'] = sum(1 for relative in old_sources if relative not in observed and relative not in relocated)
            with self.repo.connect() as db:
                db.execute('UPDATE storage_roots SET syncedAt=? WHERE id=?', (now(), root_id))
            return result

    def transfer_original(self, asset_id, body):
        if set(body) != {'revision', 'destination', 'removeLocal'} or body['destination'] not in ('local', 'development-remote') or type(body['removeLocal']) is not bool:
            raise VaultError('invalid_request', '転送の指定が不正です。')
        remote = body['destination'] == 'development-remote'
        if remote != body['removeLocal']:
            raise VaultError('invalid_request', 'アップロードは照合後にローカル原本を削除する移動操作です。')
        with self.lock:
            with self.repo.connect() as db:
                self.require_revision(db, asset_id, body['revision'])
                if db.execute('SELECT trashedAt FROM assets WHERE id=?', (asset_id,)).fetchone()[0]:
                    raise VaultError('invalid_request', 'ごみ箱の素材は転送できません。')
                pending = db.execute('SELECT * FROM transfer_cleanup WHERE assetId=?', (asset_id,)).fetchone()
                retained = db.execute('SELECT r.objectKey FROM remote_originals r JOIN files f ON f.id=r.fileId WHERE f.assetId=?', (asset_id,)).fetchone()
            if pending:
                if not remote:
                    raise VaultError('conflict', '先にローカル原本の整理を再試行してください。', 409)
                self.complete_transfer_cleanup(asset_id)
                return self.asset(asset_id)
            asset = self.asset(asset_id)
            if asset['storageLocation'] == body['destination']:
                return asset
            original = next(f for f in asset['files'] if f['role'] == 'original')
            source = self.storage.path(original['objectKey'])
            if original['state'] != 'ready' or checksum(source) != original['sha256']:
                raise VaultError('integrity', '原本が変更または欠損しています。転送を停止しました。', 409)
            if remote:
                target_key = retained['objectKey'] if retained else f"development-remote/{asset_id}/{original['id']}-{original['sha256']}"
            else:
                target_key = f"local-originals/download-{original['id']}{Path(original['originalFilename']).suffix.lower()}"
            target = self.storage.path(target_key)
            # Never overwrite an externally edited destination on retry.
            if target.exists():
                if checksum(target) != original['sha256']:
                    raise VaultError('conflict', '転送先に異なるファイルがあります。移動してから再試行してください。', 409)
            else:
                self.storage.put(source, target_key)
            if checksum(target) != original['sha256']:
                raise VaultError('integrity', '転送先の照合に失敗しました。原本は保持しています。', 409)
            with self.repo.connect() as db:
                self.require_revision(db, asset_id, body['revision'])
                remote_key = target_key if remote else original['objectKey']
                db.execute('INSERT OR REPLACE INTO remote_originals VALUES (?,?)', (original['id'], remote_key))
                db.execute('UPDATE files SET objectKey=? WHERE id=?', (target_key, original['id']))
                db.execute("UPDATE assets SET storageLocation=?,archivedAt=CASE WHEN ?='local' THEN NULL ELSE archivedAt END,originalOwnership='managed',originalModifiedNs=?,revision=revision+1,updatedAt=? WHERE id=?", (body['destination'], body['destination'], target.stat().st_mtime_ns, now(), asset_id))
                if remote:
                    db.execute('INSERT INTO transfer_cleanup VALUES (?,?,?)', (asset_id, original['objectKey'], original['sha256']))
            if remote:
                try:
                    self.complete_transfer_cleanup(asset_id)
                except (OSError, VaultError):
                    pass  # Destination is committed; report pending cleanup for explicit retry.
            return self.asset(asset_id)

    def complete_transfer_cleanup(self, asset_id):
        with self.repo.connect() as db:
            entry = db.execute('SELECT * FROM transfer_cleanup WHERE assetId=?', (asset_id,)).fetchone()
            remote = db.execute('SELECT r.objectKey FROM remote_originals r JOIN files f ON f.id=r.fileId WHERE f.assetId=?', (asset_id,)).fetchone()
        if not entry:
            return
        if not remote or checksum(self.storage.path(remote['objectKey'])) != entry['sha256']:
            raise VaultError('integrity', 'リモート原本を照合できません。ローカル原本は保持します。', 409)
        source = self.storage.path(entry['objectKey'])
        is_reference = entry['objectKey'].startswith('references/')
        if not source.is_relative_to(self.local_directory.resolve()) and not is_reference:
            raise VaultError('invalid_request', 'ローカル画像フォルダ以外の原本は削除しません。')
        if source.exists():
            stat = source.stat()
            if checksum(source) != entry['sha256'] or (source.stat().st_dev, source.stat().st_ino, source.stat().st_size, source.stat().st_mtime_ns) != (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns):
                raise VaultError('conflict', '転送中に原本が変更されました。ローカル原本は保持します。', 409)
            source.unlink()
        with self.repo.connect() as db:
            if is_reference:
                _, root_id, relative = entry['objectKey'].split('/', 2)
                db.execute('DELETE FROM local_sources WHERE rootId=? AND relativePath=?', (root_id, relative))
            db.execute('DELETE FROM transfer_cleanup WHERE assetId=?', (asset_id,))

    def local_import(self):
        with self.lock:
            job_id = self.new_job()
            added = 0
            for path in self.local_directory.rglob('*'):
                if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(self.local_directory.resolve()) or path.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.webp', '.heic', '.heif', *VIDEO_MIMES):
                    continue
                key = path.relative_to(self.storage.root).as_posix()
                # Registered files are not re-added, including modified/missing references.
                # Changes require explicit re-registration in a later revision feature.
                with self.repo.connect() as db:
                    known = db.execute("SELECT 1 FROM files WHERE role='original' AND objectKey=?", (key,)).fetchone()
                if not known:
                    with path.open('rb') as stream:
                        self.add_stream(job_id, path.name, stream, key)
                    added += 1
                    if added >= 100:
                        break
            return self.job(job_id)

    def list_assets(self, q='', view='all', kind='', collection='', sort='added', limit=60, cursor=None, tag_ids=None, extensions=None, order=None, archive='normal', location='all', seed=''):
        if location not in ('all', 'local', 'development-remote'):
            raise VaultError('invalid_request', '保管場所が不正です。')
        if view not in ('all', 'favorites', 'archive', 'trash') or archive not in ('normal', 'archived', 'all') or sort not in ('added', 'name', 'captured', 'updated', 'size', 'random') or kind not in ('', 'image', 'photo', 'video') or order not in (None, 'asc', 'desc'):
            raise VaultError('invalid_request', '一覧条件が不正です。')
        if len(seed) > 128 or (sort == 'random' and not seed):
            raise VaultError('invalid_request', 'ランダム表示にはセッション識別子が必要です。')
        tag_ids = sorted(set(tag_ids or []))
        extensions = sorted(set(e.lower().lstrip('.') for e in (extensions or [])))
        if len(tag_ids) > 100 or len(extensions) > 100:
            raise VaultError('invalid_request', 'Too many filters')
        signature = hashlib.sha256(json.dumps([q, view, kind, collection, sort, tag_ids, extensions, order, archive, location, seed]).encode()).hexdigest()
        last = None
        if cursor:
            try:
                payload = json.loads(base64.urlsafe_b64decode(cursor))
                if payload['signature'] != signature or not isinstance(payload['last'], list) or len(payload['last']) != 2:
                    raise ValueError()
                last = payload['last']
            except (ValueError, KeyError, TypeError):
                raise VaultError('invalid_request', '一覧を更新して再読み込みしてください。')
        conditions = ["a.trashedAt IS NOT NULL" if view == 'trash' else "a.trashedAt IS NULL", "a.state != 'deleting'" if view != 'trash' else '1=1']
        params = []
        if location != 'all':
            conditions.append('a.storageLocation=?'); params.append(location)
        if view == 'archive' or (view != 'trash' and archive == 'archived'):
            conditions.append("a.archivedAt IS NOT NULL AND a.storageLocation='development-remote'")
        elif view != 'trash' and archive == 'normal':
            conditions.append('a.archivedAt IS NULL')
        if view == 'favorites':
            conditions.append('a.favorite=1')
        if kind:
            conditions.append('a.kind=?'); params.append(kind)
        if collection:
            conditions.append('EXISTS(SELECT 1 FROM asset_collections m WHERE m.assetId=a.id AND m.itemId=?)'); params.append(collection)
        for tag_id in tag_ids:
            conditions.append('EXISTS(SELECT 1 FROM asset_tags m WHERE m.assetId=a.id AND m.itemId=?)'); params.append(tag_id)
        if extensions:
            conditions.append('a.originalExtension IN (' + ','.join('?' for _ in extensions) + ')'); params.extend(extensions)
        if q:
            escaped = q.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
            term = '%' + escaped + '%'
            conditions.append("(a.name LIKE ? ESCAPE '\\' OR a.note LIKE ? ESCAPE '\\' OR EXISTS(SELECT 1 FROM files f WHERE f.assetId=a.id AND f.originalFilename LIKE ? ESCAPE '\\') OR EXISTS(SELECT 1 FROM tags t JOIN asset_tags m ON t.id=m.itemId WHERE m.assetId=a.id AND t.name LIKE ? ESCAPE '\\'))")
            params.extend([term] * 4)
        where = ' AND '.join(conditions)
        expression = {'name': 'a.name COLLATE NOCASE', 'captured': "COALESCE(a.capturedAt,'')", 'updated': 'a.updatedAt', 'size': "COALESCE((SELECT f.byteSize FROM files f WHERE f.assetId=a.id AND f.role='original'),0)", 'added': 'a.createdAt', 'random': 'session_rank(a.id)'}[sort]
        ascending = order == 'asc' or (order is None and sort == 'name')
        direction, comparison = ('ASC', '>') if ascending else ('DESC', '<')
        page_where, page_params = where, list(params)
        if last:
            page_where += f' AND ({expression}, a.id) {comparison} (?,?)'
            page_params.extend(last)
        with self.repo.connect() as db:
            db.create_function('session_rank', 1, lambda asset_id: hashlib.sha256((seed + asset_id).encode()).hexdigest(), deterministic=True)
            total = db.execute(f'SELECT COUNT(*) FROM assets a WHERE {where}', params).fetchone()[0]
            rows = db.execute(f'SELECT a.id,{expression} AS sortValue FROM assets a WHERE {page_where} ORDER BY {expression} {direction},a.id {direction} LIMIT ?', (*page_params, limit + 1)).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = base64.urlsafe_b64encode(json.dumps({'signature': signature, 'last': [rows[-1]['sortValue'], rows[-1]['id']]}).encode()).decode() if more else None
        return {'items': [self.asset(r['id']) for r in rows], 'total': total, 'nextCursor': next_cursor}

    def validate_selection(self, db, entries):
        if not isinstance(entries, list) or not 1 <= len(entries) <= 100:
            raise VaultError('invalid_request', '1〜100点の素材を選択してください。')
        ids = set()
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {'id', 'revision'} or not isinstance(entry['id'], str) or entry['id'] in ids:
                raise VaultError('invalid_request', '選択内容が不正です。')
            ids.add(entry['id'])
            self.require_revision(db, entry['id'], entry['revision'])
            if db.execute('SELECT trashedAt FROM assets WHERE id=?', (entry['id'],)).fetchone()[0]:
                raise VaultError('invalid_request', 'ごみ箱の素材は対象外です。')

    def bulk_organize(self, body):
        if set(body) != {'assets', 'entity', 'itemIds', 'mode'} or body['entity'] not in ('tags', 'collections') or body['mode'] not in ('add', 'replace'):
            raise VaultError('invalid_request', '一括設定の指定が不正です。')
        ids, entity = body['itemIds'], body['entity']
        if not isinstance(ids, list) or len(ids) > 100 or any(not isinstance(i, str) for i in ids) or len(set(ids)) != len(ids):
            raise VaultError('invalid_request', 'タグ・コレクションの指定が不正です。')
        with self.lock, self.repo.connect() as db:
            self.validate_selection(db, body['assets'])
            if any(not db.execute(f'SELECT 1 FROM {entity} WHERE id=?', (i,)).fetchone() for i in ids):
                raise VaultError('invalid_request', 'タグ・コレクションが見つかりません。')
            timestamp = now()
            for entry in body['assets']:
                if body['mode'] == 'replace':
                    db.execute(f'DELETE FROM asset_{entity} WHERE assetId=?', (entry['id'],))
                db.executemany(f'INSERT OR IGNORE INTO asset_{entity} VALUES (?,?)', [(entry['id'], i) for i in ids])
                db.execute('UPDATE assets SET updatedAt=?,revision=revision+1 WHERE id=?', (timestamp, entry['id']))
        return {'updated': len(body['assets'])}

    @staticmethod
    def validate_archive_flag(archived):
        if type(archived) is not bool:
            raise VaultError('invalid_request', 'アーカイブ状態の指定が不正です。')

    @staticmethod
    def set_archive(db, archived, conditions, params):
        timestamp = now()
        return db.execute(
            f"UPDATE assets SET archivedAt=?,updatedAt=?,revision=revision+1 WHERE {conditions} AND storageLocation='development-remote' AND archivedAt IS {'NULL' if archived else 'NOT NULL'}",
            (timestamp if archived else None, timestamp, *params),
        ).rowcount

    def archive_asset(self, asset_id, body):
        if set(body) != {'revision', 'archived'}:
            raise VaultError('invalid_request', 'アーカイブ操作の指定が不正です。')
        self.bulk_archive({'assets': [{'id': asset_id, 'revision': body['revision']}], 'archived': body['archived']})
        return self.asset(asset_id)

    def bulk_archive(self, body):
        if set(body) != {'assets', 'archived'}:
            raise VaultError('invalid_request', 'アーカイブ操作の指定が不正です。')
        self.validate_archive_flag(body['archived'])
        with self.lock, self.repo.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            self.validate_selection(db, body['assets'])
            ids = [entry['id'] for entry in body['assets']]
            if db.execute("SELECT 1 FROM assets WHERE storageLocation='local' AND id IN (" + ','.join('?' for _ in ids) + ')', ids).fetchone():
                raise VaultError('invalid_request', 'アーカイブはリモート素材専用です。')
            updated = self.set_archive(db, body['archived'], 'id IN (' + ','.join('?' for _ in ids) + ')', ids)
        return {'updated': updated}

    @staticmethod
    def collection_archive_snapshot(db, collection_id):
        if not db.execute('SELECT 1 FROM collections WHERE id=?', (collection_id,)).fetchone():
            raise VaultError('not_found', 'コレクションが見つかりません。', 404)
        rows = db.execute("SELECT a.id,a.revision,a.archivedAt FROM assets a JOIN asset_collections m ON m.assetId=a.id WHERE m.itemId=? AND a.storageLocation='development-remote' AND a.trashedAt IS NULL AND a.state!='deleting' ORDER BY a.id", (collection_id,)).fetchall()
        token = hashlib.sha256(json.dumps([collection_id, [tuple(r) for r in rows]]).encode()).hexdigest()
        archived = sum(r['archivedAt'] is not None for r in rows)
        return {'normalCount': len(rows) - archived, 'archiveCount': archived, 'token': token}

    def collection_archive_summary(self, collection_id):
        with self.repo.connect() as db:
            return self.collection_archive_snapshot(db, collection_id)

    def archive_collection(self, collection_id, body):
        if set(body) != {'archived', 'token'} or not isinstance(body['token'], str):
            raise VaultError('invalid_request', 'コレクション操作の指定が不正です。')
        self.validate_archive_flag(body['archived'])
        with self.lock, self.repo.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            snapshot = self.collection_archive_snapshot(db, collection_id)
            if snapshot['token'] != body['token']:
                raise VaultError('conflict', 'コレクションの素材が更新されました。対象件数を読み込み直してください。', 409)
            updated = self.set_archive(db, body['archived'], "trashedAt IS NULL AND state!='deleting' AND id IN (SELECT assetId FROM asset_collections WHERE itemId=?)", [collection_id])
        return {'updated': updated}

    def entities(self, entity):
        with self.repo.connect() as db:
            return [dict(r) for r in db.execute(f'SELECT * FROM {entity} ORDER BY name')]

    def create_entity(self, entity, name):
        name = name.strip()
        if not name or len(name) > 100:
            raise VaultError('invalid_request', '名前は1〜100文字で入力してください。')
        with self.lock, self.repo.connect() as db:
            existing = db.execute(f'SELECT * FROM {entity} WHERE name=?', (name,)).fetchone()
            if existing:
                return dict(existing)
            item = {'id': identifier(), 'name': name}
            db.execute(f'INSERT INTO {entity} VALUES (?,?)', (item['id'], name))
            return item

    def update(self, asset_id, changes):
        allowed = {'revision', 'name', 'note', 'kind', 'favorite', 'tagIds', 'collectionIds'}
        if set(changes) - allowed:
            raise VaultError('invalid_request', '変更項目が不正です。')
        with self.lock, self.repo.connect() as db:
            self.require_revision(db, asset_id, changes.get('revision'))
            for field in ('name', 'note', 'kind'):
                if field in changes:
                    value = changes[field]
                    if not isinstance(value, str) or (field != 'note' and not value.strip()) or len(value) > (5000 if field == 'note' else 255):
                        raise VaultError('invalid_request', '入力文字数または内容が不正です。')
                    if field == 'kind' and value not in ('image', 'photo', 'video'):
                        raise VaultError('invalid_request', '写真・画像・動画の種別を指定してください。')
                    db.execute(f'UPDATE assets SET {field}=? WHERE id=?', (value.strip(), asset_id))
            if 'favorite' in changes:
                if type(changes['favorite']) is not bool:
                    raise VaultError('invalid_request', 'お気に入りの指定が不正です。')
                db.execute('UPDATE assets SET favorite=? WHERE id=?', (int(changes['favorite']), asset_id))
            for field, entity in [('tagIds', 'tags'), ('collectionIds', 'collections')]:
                if field in changes:
                    ids = changes[field]
                    if not isinstance(ids, list) or len(ids) > 100 or any(not isinstance(i, str) for i in ids) or len(set(ids)) != len(ids):
                        raise VaultError('invalid_request', '所属の指定が不正です。')
                    if any(not db.execute(f'SELECT 1 FROM {entity} WHERE id=?', (i,)).fetchone() for i in ids):
                        raise VaultError('invalid_request', 'タグまたはコレクションが見つかりません。')
                    db.execute(f'DELETE FROM asset_{entity} WHERE assetId=?', (asset_id,))
                    db.executemany(f'INSERT INTO asset_{entity} VALUES (?,?)', [(asset_id, i) for i in ids])
            db.execute('UPDATE assets SET revision=revision+1,updatedAt=? WHERE id=?', (now(), asset_id))
        return self.asset(asset_id)

    @staticmethod
    def require_revision(db, asset_id, revision):
        row = db.execute('SELECT revision,state FROM assets WHERE id=?', (asset_id,)).fetchone()
        if not row:
            raise VaultError('not_found', '素材が見つかりません。', 404)
        if type(revision) is not int or row['revision'] != revision:
            raise VaultError('conflict', '別の画面で更新されました。再読み込みしてください。', 409)
        if row['state'] == 'deleting':
            raise VaultError('conflict', '削除処理中です。削除を再試行してください。', 409)

    def trash(self, asset_id, revision, restore=False):
        with self.lock, self.repo.connect() as db:
            self.require_revision(db, asset_id, revision)
            db.execute('UPDATE assets SET trashedAt=?,updatedAt=?,revision=revision+1 WHERE id=?', (None if restore else now(), now(), asset_id))
        return self.asset(asset_id)

    def delete(self, asset_id, revision):
        with self.lock:
            asset = self.asset(asset_id)
            if not asset['trashedAt']:
                raise VaultError('invalid_request', '完全削除はごみ箱から実行してください。')
            with self.repo.connect() as db:
                if asset['state'] != 'deleting':
                    self.require_revision(db, asset_id, revision)
                    db.execute("UPDATE assets SET state='deleting',revision=revision+1 WHERE id=?", (asset_id,))
                elif revision != asset['revision']:
                    raise VaultError('conflict', '最新の削除状態を読み込んでください。', 409)
            self.finish_delete(asset_id)

    def finish_delete(self, asset_id):
        asset = self.repo.asset(asset_id)
        with self.repo.connect() as db:
            remote_keys = [r[0] for r in db.execute('SELECT r.objectKey FROM remote_originals r JOIN files f ON f.id=r.fileId WHERE f.assetId=?', (asset_id,))]
        for key in remote_keys:
            self.storage.delete(key)
        for f in asset['files']:
            if f['role'] == 'original' and asset['originalOwnership'] == 'reference':
                continue
            self.storage.delete(f['objectKey'])
        with self.repo.connect() as db:
            db.execute('DELETE FROM assets WHERE id=?', (asset_id,))

    def status(self):
        with self.repo.connect() as db:
            count = db.execute('SELECT COUNT(*) FROM assets WHERE trashedAt IS NULL').fetchone()[0]
            archived = db.execute('SELECT COUNT(*) FROM assets WHERE trashedAt IS NULL AND archivedAt IS NOT NULL').fetchone()[0]
            size = db.execute('SELECT COALESCE(SUM(byteSize),0) FROM files').fetchone()[0]
            size += db.execute('SELECT COALESCE(SUM(f.byteSize),0) FROM files f JOIN remote_originals r ON r.fileId=f.id WHERE r.objectKey!=f.objectKey').fetchone()[0]
            local_count = db.execute("SELECT COUNT(*) FROM assets WHERE trashedAt IS NULL AND storageLocation='local'").fetchone()[0]
        return {'mode': 'local', 'storageMode': 'development-hybrid', 'localDirectory': str(self.local_directory), 'localCount': local_count, 'remoteCount': count - local_count, 'assetCount': count, 'normalCount': count - archived, 'archiveCount': archived, 'byteSize': size, 'formats': ['JPEG', 'PNG', 'WebP', 'HEIC（原本のみ）', 'MP4 / MOV / WebM / MKV / AVI / M4V（閲覧用生成にはFFmpegが必要）']}
