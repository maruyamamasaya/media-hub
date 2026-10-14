import os
import secrets
import tempfile
import zipfile
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request, Response, UploadFile, File, Query
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from starlette.background import BackgroundTask
from .service import Vault, VaultError
from .folder_upload import FolderUploads
from .light_video import LightVideos
from .folder_privacy import FolderPrivacy

ROOT = Path(__file__).resolve().parents[2]
ALLOWED_ORIGINS = {'http://127.0.0.1:5173', 'http://localhost:5173', 'http://127.0.0.1:8765', 'http://localhost:8765'}


def create_app(data_root=None, fixtures=None, *, desktop_token=None, desktop_origin=None, cloud_only=False, privacy_enabled=False):
    if (desktop_token is None) != (desktop_origin is None):
        raise ValueError('Desktop token and origin must be supplied together')
    if os.getenv('ASSET_LIBRARY_MODE', 'local') != 'local':
        raise RuntimeError('This API supports loopback local development only')
    vault = Vault(data_root or ROOT / '.local/asset-library', fixtures or ROOT / '.local/fixtures')
    @asynccontextmanager
    async def lifespan(app):
        yield
        light_videos.shutdown()

    app = FastAPI(title='Asset Library local API', version='1.0.0', lifespan=lifespan)
    app.state.vault = vault
    folder_uploads = FolderUploads(vault.root)
    app.state.folder_uploads = folder_uploads
    privacy = FolderPrivacy(folder_uploads)
    def folder_grant(request):
        return request.headers.get('x-folder-unlock', '') or request.cookies.get('folder_grant', '')
    light_videos = LightVideos(vault.root)
    app.state.light_videos = light_videos

    @app.middleware('http')
    async def local_boundary(request, call_next):
        if desktop_token is not None:
            if request.headers.get('host') != desktop_origin.removeprefix('http://'):
                return JSONResponse({'code': 'forbidden_host', 'message': 'ローカル接続のみ利用できます。'}, status_code=403)
            if not secrets.compare_digest(request.headers.get('x-photo-hub-token', ''), desktop_token):
                return JSONResponse({'code': 'unauthorized', 'message': 'アプリから接続してください。'}, status_code=401)
        host = request.headers.get('host', '').split(':')[0]
        if host not in ('127.0.0.1', 'localhost'):
            return JSONResponse({'code': 'forbidden_host', 'message': 'ローカル接続のみ利用できます。'}, status_code=403)
        origin = request.headers.get('origin')
        if origin and origin not in ({desktop_origin} if desktop_token else ALLOWED_ORIGINS):
            return JSONResponse({'code': 'forbidden_origin', 'message': 'この画面からのアクセスは許可されていません。'}, status_code=403)
        if request.headers.get('sec-fetch-site') == 'cross-site':
            return JSONResponse({'code': 'forbidden_origin', 'message': '別サイトからのアクセスは許可されていません。'}, status_code=403)
        if cloud_only and request.url.path.startswith('/api/v1/') and not (
            request.url.path == '/api/v1/status' or request.url.path.startswith('/api/v1/folder-uploads')
            or request.url.path.startswith('/api/v1/folder-library')
            or request.url.path.startswith('/api/v1/light-videos')
            or request.url.path.startswith('/api/v1/folder-locks')
        ):
            return JSONResponse({'code': 'cloud_only', 'message': '原本はS3で管理します。ローカルライブラリ機能は終了しました。'}, status_code=410)
        try:
            length = int(request.headers.get('content-length', '0'))
        except ValueError:
            length = -1
        if length < 0 or length > 500 * 1024 * 1024:
            return JSONResponse({'code': 'too_large', 'message': '一度に追加できる容量は500MBまでです。'}, status_code=413)
        # Reject streaming/chunked bodies without a bound before multipart spooling.
        if 'content-length' not in request.headers and ('transfer-encoding' in request.headers or 'multipart/' in request.headers.get('content-type', '')):
            return JSONResponse({'code': 'invalid_request', 'message': 'リクエストのサイズを指定してください。'}, status_code=411)
        response = await call_next(request)
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Referrer-Policy'] = 'no-referrer'
        if desktop_token:
            response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; frame-src 'none'; base-uri 'none'; frame-ancestors 'none'"
            response.headers['Cache-Control'] = 'no-store'
        return response

    @app.exception_handler(VaultError)
    async def known_error(request, exc):
        return JSONResponse({'code': exc.code, 'message': exc.message}, status_code=exc.status)

    @app.exception_handler(OSError)
    async def storage_error(request, exc):
        return JSONResponse({'code': 'storage_error', 'message': '保存に失敗しました。空き容量を確認して再試行してください。'}, status_code=507)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        return JSONResponse({'code': 'invalid_request', 'message': 'リクエスト内容を確認してください。'}, status_code=400)

    @app.get('/api/v1/status')
    def status():
        return vault.status()

    @app.get('/api/v1/folder-uploads')
    def folder_upload_list(request: Request):
        return privacy.plans(folder_grant(request)) if privacy_enabled else folder_uploads.list()

    @app.get('/api/v1/light-videos')
    def light_video_list(request: Request):
        values = light_videos.list()
        if not privacy_enabled:
            return values
        results = []
        for value in values:
            plan_id = light_videos.read(value['id']).get('uploadPlanId')
            if plan_id:
                try:
                    privacy.require_full_plan(plan_id, folder_grant(request))
                except VaultError as exc:
                    if exc.code == 'folder_locked':
                        continue
                    raise
            results.append(value)
        return results

    @app.post('/api/v1/light-videos/inspect')
    def light_video_inspect(body: dict):
        return light_videos.inspect(body)

    @app.post('/api/v1/light-videos/{job_id}/start')
    def light_video_start(job_id: str):
        return light_videos.start(job_id)

    @app.post('/api/v1/light-videos/{job_id}/cancel')
    def light_video_cancel(job_id: str):
        return light_videos.cancel(job_id)

    @app.post('/api/v1/light-videos/{job_id}/prepare-upload')
    def light_video_prepare_upload(job_id: str, request: Request):
        plan_id = light_videos.read(job_id).get('uploadPlanId')
        if privacy_enabled and plan_id:
            privacy.require_full_plan(plan_id, folder_grant(request))
        return light_videos.prepare_upload(job_id, folder_uploads)

    @app.get('/api/v1/light-videos/{job_id}/content')
    def light_video_content(job_id: str, request: Request, download: bool = False):
        plan_id = light_videos.read(job_id).get('uploadPlanId')
        if privacy_enabled and plan_id:
            privacy.require_full_plan(plan_id, folder_grant(request))
        path, name = light_videos.content(job_id)
        return FileResponse(path, media_type='video/mp4', filename=name,
            content_disposition_type='attachment' if download else 'inline', headers={'Cache-Control': 'private, no-store'})

    @app.get('/api/v1/folder-library')
    def folder_library(request: Request):
        return privacy.library(folder_grant(request)) if privacy_enabled else folder_uploads.library()

    @app.post('/api/v1/folder-locks/unlock')
    def folder_unlock(body: dict, request: Request, response: Response):
        result = privacy.unlock(body, folder_grant(request))
        response.set_cookie('folder_grant', result['token'], max_age=300, httponly=True, samesite='strict', path='/api/v1')
        return {'expiresIn': result['expiresIn']}

    @app.post('/api/v1/folder-locks/relock')
    def folder_relock(response: Response):
        response.delete_cookie('folder_grant', path='/api/v1')
        return {'locked': True}

    @app.post('/api/v1/folder-locks/settings')
    def folder_lock_settings(body: dict, request: Request):
        return privacy.set(body, folder_grant(request))

    @app.get('/api/v1/folder-library/{plan_id}/items/{item_id}/content')
    def folder_media(plan_id: str, item_id: str, request: Request, thumbnail: bool = False, download: bool = False):
        if privacy_enabled:
            privacy.authorize(plan_id, item_id, folder_grant(request))
        path, mime, name = folder_uploads.media(plan_id, item_id, thumbnail)
        return FileResponse(path, media_type=mime, filename=name,
                            content_disposition_type='attachment' if download else 'inline',
                            headers={'Cache-Control': 'private, no-store'})

    @app.post('/api/v1/folder-uploads/scan')
    def folder_upload_scan(body: dict, request: Request):
        result = folder_uploads.scan(body)
        if privacy_enabled:
            privacy.require_full_plan(result['id'], folder_grant(request))
        return result

    @app.get('/api/v1/folder-uploads/{plan_id}')
    def folder_upload_status(plan_id: str, request: Request):
        with folder_uploads.lock:
            return privacy.plan(plan_id, folder_grant(request)) if privacy_enabled else folder_uploads.public(folder_uploads.read(plan_id))

    @app.post('/api/v1/folder-uploads/{plan_id}/start')
    def folder_upload_start(plan_id: str, body: dict, request: Request):
        if privacy_enabled:
            privacy.require_full_plan(plan_id, folder_grant(request))
        return folder_uploads.start(plan_id, body)

    @app.post('/api/v1/folder-uploads/{plan_id}/pause')
    def folder_upload_pause(plan_id: str, request: Request):
        result = folder_uploads.pause(plan_id)
        return privacy.plan(plan_id, folder_grant(request)) if privacy_enabled else result

    @app.get('/api/v1/filter-options')
    def filter_options():
        with vault.repo.connect() as db:
            return {'extensions': [r[0] for r in db.execute("SELECT DISTINCT originalExtension FROM assets WHERE originalExtension!='' ORDER BY originalExtension")]}

    @app.get('/api/v1/assets')
    def assets(q: str = '', view: str = 'all', kind: str = '', collection: str = '', sort: str = 'added', limit: int = Query(60, ge=1, le=100), cursor: str | None = None, tag: list[str] = Query(default=[]), extension: list[str] = Query(default=[]), order: str | None = None, archive: str = 'normal', location: str = 'all'):
        return vault.list_assets(q, view, kind, collection, sort, limit, cursor, tag, extension, order, archive, location)

    @app.post('/api/v1/import-local-directory')
    def import_local_directory():
        return vault.local_import()

    @app.get('/api/v1/storage-roots')
    def storage_roots():
        return vault.storage_roots()

    @app.post('/api/v1/sync-directory')
    def sync_directory(body: dict):
        return vault.sync_directory(body)

    @app.post('/api/v1/bulk-archive')
    def bulk_archive(body: dict):
        return vault.bulk_archive(body)

    @app.post('/api/v1/bulk-organize')
    def bulk_organize(body: dict):
        return vault.bulk_organize(body)

    @app.post('/api/v1/bulk-download')
    def bulk_download(body: dict):
        if set(body) != {'assets'}:
            raise VaultError('invalid_request', '選択内容が不正です。')
        archive_path = None
        try:
            with vault.lock, vault.repo.connect() as db:
                vault.validate_selection(db, body['assets'])
                originals = []
                for entry in body['assets']:
                    original = db.execute("SELECT * FROM files WHERE assetId=? AND role='original' AND state='ready'", (entry['id'],)).fetchone()
                    if not original or not vault.storage.path(original['objectKey']).is_file():
                        raise VaultError('missing_file', '原本が見つかりません。', 404)
                    if next(f for f in vault.asset(entry['id'])['files'] if f['role'] == 'original')['state'] != 'ready':
                        raise VaultError('changed_file', '原本が変更されています。登録時の状態に戻してください。', 409)
                    originals.append(original)
                if sum(f['byteSize'] for f in originals) > 1024 * 1024 * 1024:
                    raise VaultError('too_large', '一括ダウンロードは原本合計1GBまでです。', 413)
                with tempfile.NamedTemporaryFile(suffix='.zip', delete=False) as temporary:
                    archive_path = Path(temporary.name)
                with zipfile.ZipFile(archive_path, 'w', compression=zipfile.ZIP_STORED) as archive:
                    for index, original in enumerate(originals, 1):
                        name = Path(original['originalFilename'].replace('\\', '/')).name
                        archive.write(vault.storage.path(original['objectKey']), f'{index:03d}_{name}')
            return FileResponse(archive_path, media_type='application/zip', filename='assets.zip', background=BackgroundTask(archive_path.unlink, missing_ok=True))
        except Exception:
            if archive_path:
                archive_path.unlink(missing_ok=True)
            raise

    @app.get('/api/v1/assets/{asset_id}')
    def asset(asset_id: str):
        return vault.asset(asset_id)

    @app.post('/api/v1/imports')
    def import_files(files: list[UploadFile] = File(...)):
        if len(files) > 100:
            raise VaultError('invalid_request', '一度に選べるファイルは100件までです。')
        job_id = vault.new_job()
        for upload in files:
            try:
                vault.add_stream(job_id, upload.filename or 'image', upload.file)
            finally:
                upload.file.close()
        return vault.job(job_id)

    @app.get('/api/v1/imports/{job_id}')
    def import_job(job_id: str):
        return vault.job(job_id)

    @app.post('/api/v1/imports/{job_id}/retry')
    def retry_import(job_id: str):
        return vault.retry_job(job_id)

    @app.post('/api/v1/fixture-imports')
    def fixture_import():
        return vault.fixture_import()

    @app.patch('/api/v1/assets/{asset_id}')
    def update_asset(asset_id: str, changes: dict):
        return vault.update(asset_id, changes)

    @app.post('/api/v1/assets/{asset_id}/trash')
    def trash_asset(asset_id: str, body: dict):
        return vault.trash(asset_id, body.get('revision'))

    @app.post('/api/v1/assets/{asset_id}/archive')
    def archive_asset(asset_id: str, body: dict):
        return vault.archive_asset(asset_id, body)

    @app.post('/api/v1/assets/{asset_id}/transfer')
    def transfer_original(asset_id: str, body: dict):
        return vault.transfer_original(asset_id, body)

    @app.post('/api/v1/assets/{asset_id}/restore')
    def restore_asset(asset_id: str, body: dict):
        return vault.trash(asset_id, body.get('revision'), restore=True)

    @app.delete('/api/v1/assets/{asset_id}')
    def delete_asset(asset_id: str, body: dict):
        vault.delete(asset_id, body.get('revision'))
        return {'deleted': True}

    @app.post('/api/v1/assets/{asset_id}/preview-retry')
    def retry_preview(asset_id: str):
        with vault.lock:
            return vault.preview(asset_id)

    @app.get('/api/v1/assets/{asset_id}/files/{file_id}/content')
    def file_content(asset_id: str, file_id: str, download: bool = False):
        asset = vault.asset(asset_id)
        entry = next((f for f in asset['files'] if f['id'] == file_id), None)
        if not entry or entry['state'] != 'ready':
            raise VaultError('missing_file', '保存ファイルが見つかりません。', 404)
        path = vault.storage.path(entry['objectKey'])
        return FileResponse(path, media_type=entry['mimeType'], filename=entry['originalFilename'], content_disposition_type='attachment' if download else 'inline')

    @app.get('/api/v1/tags')
    def tags():
        return vault.entities('tags')

    @app.post('/api/v1/tags')
    def create_tag(body: dict):
        return vault.create_entity('tags', safe_name(body))

    @app.get('/api/v1/collections')
    def collections():
        return vault.entities('collections')

    @app.post('/api/v1/collections')
    def create_collection(body: dict):
        return vault.create_entity('collections', safe_name(body))

    @app.patch('/api/v1/collections/{collection_id}')
    def rename_collection(collection_id: str, body: dict):
        name = safe_name(body).strip()
        if not name or len(name) > 100:
            raise VaultError('invalid_request', '名前は1〜100文字で入力してください。')
        with vault.lock, vault.repo.connect() as db:
            exists = db.execute('SELECT id FROM collections WHERE name=? AND id!=?', (name, collection_id)).fetchone()
            if exists:
                raise VaultError('conflict', '同じ名前のコレクションがあります。', 409)
            if not db.execute('UPDATE collections SET name=? WHERE id=?', (name, collection_id)).rowcount:
                raise VaultError('not_found', 'コレクションが見つかりません。', 404)
        return {'id': collection_id, 'name': name}

    @app.get('/api/v1/collections/{collection_id}/archive-summary')
    def collection_archive_summary(collection_id: str):
        return vault.collection_archive_summary(collection_id)

    @app.post('/api/v1/collections/{collection_id}/archive')
    def archive_collection(collection_id: str, body: dict):
        return vault.archive_collection(collection_id, body)

    @app.delete('/api/v1/collections/{collection_id}')
    def delete_collection(collection_id: str):
        with vault.lock, vault.repo.connect() as db:
            members = [r['assetId'] for r in db.execute('SELECT assetId FROM asset_collections WHERE itemId=?', (collection_id,))]
            db.execute('DELETE FROM collections WHERE id=?', (collection_id,))
            db.executemany('UPDATE assets SET revision=revision+1 WHERE id=?', [(i,) for i in members])
        return {'deleted': True}

    dist = ROOT / 'web/dist'
    if dist.is_dir():
        app.mount('/', StaticFiles(directory=dist, html=True), name='web')
    return app


def safe_name(body):
    if set(body) != {'name'} or not isinstance(body['name'], str):
        raise VaultError('invalid_request', '名前の指定が不正です。')
    return body['name']
