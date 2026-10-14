import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reader
import folder_security

OWNER = '00000000-0000-4000-8000-000000000001'
ROOT = '00000000-0000-4000-8000-000000000002'
UPLOAD = '00000000-0000-4000-8000-000000000003'
FOLDER = '00000000-0000-4000-8000-000000000004'
ITEM = '00000000-0000-4000-8000-000000000005'
SHA = 'a' * 64

class Fake:
    def __init__(self):
        self.value = {'schemaVersion': 1, 'id': UPLOAD, 'rootId': ROOT, 'name': 'Demo', 'folders': [{'id': FOLDER, 'name': 'Demo', 'parentId': None}], 'items': [{'id': ITEM, 'name': 'sample.jpg', 'folderId': FOLDER, 'byteSize': 12, 'sha256': SHA, 'mimeType': 'image/jpeg', 'objectKey': f'media-hub/originals/{ITEM}/{SHA}', 'versionId': 'v1'}]}
        self.signed = []
        self.settings = folder_security.empty_settings()
    def list_objects_v2(self, **args):
        assert args['Prefix'] == 'media-hub/catalogs/'
        return {'Contents': [{'Key': f'media-hub/catalogs/{ROOT}/{UPLOAD}.json', 'LastModified': 1}]}
    def get_object(self, **args):
        if args['Key'] == folder_security.KEY:
            return {'Body': io.BytesIO(json.dumps(self.settings).encode())}
        return {'Body': io.BytesIO(json.dumps(self.value).encode())}
    def generate_presigned_url(self, operation, **args):
        self.signed.append((operation, args))
        return 'https://private.s3.ap-northeast-1.amazonaws.com/test-signature'

class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.environment = patch.dict(os.environ, {'BUCKET': 'test-bucket', 'OWNER_SUB': OWNER})
        self.environment.start(); self.addCleanup(self.environment.stop)
        self.client = patch('reader.client', return_value=self.fake)
        self.client.start(); self.addCleanup(self.client.stop)
    def call(self, path='/library', method='GET', owner=OWNER, query=None, headers=None, body=None):
        return reader.handler({'rawPath': path, 'headers': headers or {}, 'body': json.dumps(body) if body else '', 'queryStringParameters': query, 'requestContext': {'http': {'method': method}, 'authorizer': {'jwt': {'claims': {'sub': owner} if owner else {}}}}}, None)

    def test_thumbnail_batch_uses_one_catalog_read_and_rejects_hidden_members(self):
        self.fake.value['items'][0]['thumbnailKey'] = f'media-hub/thumbnails/{ITEM}/{SHA}.png'
        with patch.object(self.fake, 'get_object', wraps=self.fake.get_object) as get:
            result = self.call(f'/catalogs/{ROOT}/{UPLOAD}', query={'thumbnailIds': ITEM})
            self.assertEqual(result['statusCode'], 200)
            self.assertEqual(set(json.loads(result['body'])['urls']), {ITEM})
            self.assertEqual(get.call_count, 2)  # Lock settings + one catalog.
        self.fake.signed.clear()
        for ids, status in [(ITEM + ',' + FOLDER, 404), (','.join([ITEM] * 61), 400), (ITEM + ',' + ITEM, 400)]:
            self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}', query={'thumbnailIds': ids})['statusCode'], status)
            self.assertEqual(self.fake.signed, [])
        self.fake.settings['locks'] = [folder_security.make_lock(ROOT, FOLDER, '012345')]
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}', query={'thumbnailIds': ITEM})['statusCode'], 404)
        self.assertEqual(self.fake.signed, [])

    def test_sixty_thumbnails_need_only_one_catalog_fetch(self):
        import uuid
        items = []
        for _ in range(60):
            identity = str(uuid.uuid4())
            item = dict(self.fake.value['items'][0], id=identity, objectKey=f'media-hub/originals/{identity}/{SHA}', thumbnailKey=f'media-hub/thumbnails/{identity}/{SHA}.png')
            items.append(item)
        self.fake.value['items'] = items
        with patch.object(self.fake, 'get_object', wraps=self.fake.get_object) as get:
            result = self.call(f'/catalogs/{ROOT}/{UPLOAD}', query={'thumbnailIds': ','.join(i['id'] for i in items)})
        self.assertEqual(result['statusCode'], 200)
        self.assertEqual(len(json.loads(result['body'])['urls']), 60)
        self.assertEqual(get.call_count, 2)
        self.assertEqual(len(self.fake.signed), 60)
        self.assertTrue(all(args['ExpiresIn'] == 300 for _, args in self.fake.signed))

    def test_locked_root_hidden_catalog_and_url_until_owner_password(self):
        self.fake.settings['locks'] = [folder_security.make_lock(ROOT, FOLDER, '012345')]
        self.assertEqual(json.loads(self.call()['body']), [])
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}')['statusCode'], 404)
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}/items/{ITEM}/url')['statusCode'], 404)
        self.assertEqual(self.fake.signed, [])
        result = self.call('/folder-unlock', method='POST', body={'password':'012345'})
        token = json.loads(result['body'])['token']
        self.assertEqual(len(json.loads(self.call(headers={'X-Folder-Unlock':token})['body'])), 1)
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}/items/{ITEM}/url', headers={'X-Folder-Unlock':token})['statusCode'], 200)
        self.assertEqual(self.call('/folder-unlock', method='POST', body={'password':'wrong-password'})['statusCode'], 403)

    def test_unlock_requires_owner_and_never_returns_verifiers(self):
        self.fake.settings['locks'] = [folder_security.make_lock(ROOT, FOLDER, '012345')]
        result = self.call('/folder-unlock', method='POST', owner=ROOT, body={'password':'012345'})
        self.assertEqual(result['statusCode'], 403)
        self.assertNotIn('012345', result['body'])
        result = self.call('/folder-unlock', method='POST', body={'password':'012345'})
        self.assertNotIn('verifier', result['body'])
        self.fake.settings['revision'] = FOLDER
        token = json.loads(result['body'])['token']
        self.assertEqual(json.loads(self.call(headers={'x-folder-unlock': token})['body']), [])
    def test_library_and_public_contract(self):
        response = self.call()
        self.assertEqual(response['statusCode'], 200)
        self.assertEqual(json.loads(response['body'])[0]['itemCount'], 1)
        response = self.call(f'/catalogs/{ROOT}/{UPLOAD}')
        value = json.loads(response['body'])
        self.assertEqual(value['items'][0]['hasThumbnail'], False)
        self.assertNotIn('objectKey', value['items'][0])
        self.assertNotIn('url', value['items'][0])
    def test_owner_and_authentication_required(self):
        self.assertEqual(self.call(owner=None)['statusCode'], 401)
        self.assertEqual(self.call(owner=ROOT)['statusCode'], 403)
        self.assertEqual(self.fake.signed, [])
    def test_all_write_methods_denied(self):
        for method in ['POST', 'PUT', 'PATCH', 'DELETE']:
            self.assertEqual(self.call(method=method)['statusCode'], 405)
        self.assertEqual(self.fake.signed, [])
    def test_get_url_is_pinned_and_short_lived(self):
        response = self.call(f'/catalogs/{ROOT}/{UPLOAD}/items/{ITEM}/url')
        self.assertEqual(response['statusCode'], 200)
        operation, args = self.fake.signed[0]
        self.assertEqual(operation, 'get_object')
        self.assertEqual(args['Params']['VersionId'], 'v1')
        self.assertEqual(args['ExpiresIn'], 300)
        self.assertEqual(args['HttpMethod'], 'GET')
    def test_item_membership_and_thumbnail_no_fallback_original(self):
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}/items/{FOLDER}/url')['statusCode'], 404)
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}/items/{ITEM}/url', query={'role':'thumbnail'})['statusCode'], 404)
        self.assertEqual(self.fake.signed, [])
    def test_catalog_cannot_grant_arbitrary_key(self):
        self.fake.value['items'][0]['objectKey'] = 'another-app/private-file'
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}/items/{ITEM}/url')['statusCode'], 400)
        self.assertEqual(self.fake.signed, [])

    def test_private_thumbnail_requires_owner_and_folder_unlock(self):
        key = f'media-hub/thumbnails/{ITEM}/{SHA}.png'
        self.fake.value['items'][0]['thumbnailKey'] = key
        endpoint = f'/catalogs/{ROOT}/{UPLOAD}/items/{ITEM}/url'
        self.assertEqual(self.call(endpoint, owner=None, query={'role': 'thumbnail'})['statusCode'], 401)
        self.fake.settings['locks'] = [folder_security.make_lock(ROOT, FOLDER, '012345')]
        self.assertEqual(self.call(endpoint, query={'role': 'thumbnail'})['statusCode'], 404)
        self.assertEqual(self.fake.signed, [])
        token = json.loads(self.call('/folder-unlock', method='POST', body={'password': '012345'})['body'])['token']
        self.assertEqual(self.call(endpoint, query={'role': 'thumbnail'}, headers={'X-Folder-Unlock': token})['statusCode'], 200)
        params = self.fake.signed[-1][1]
        self.assertEqual(params['Params']['Key'], key)
        self.assertEqual(params['Params']['ResponseCacheControl'], 'private, no-store')
        self.assertEqual(params['ExpiresIn'], 300)
    def test_invalid_folder_tree_denied(self):
        self.fake.value['folders'].append({'id': ROOT, 'name': 'cycle', 'parentId': ROOT})
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}')['statusCode'], 400)
    def test_storage_failure_does_not_expose_exception_or_url(self):
        with patch.object(self.fake, 'get_object', side_effect=Exception('SECRET JWT https://signed.url')):
            response = self.call()
        self.assertEqual(response['statusCode'], 502)
        self.assertNotIn('SECRET', response['body'])
        self.assertNotIn('signed.url', response['body'])

    def test_trash_excludes_items_and_denies_original_and_thumbnail_urls(self):
        self.fake.value['trash'] = [{'id': OWNER, 'name': 'sample', 'state': 'trashed', 'itemIds': [ITEM], 'folderIds': []}]
        self.assertEqual(json.loads(self.call()['body'])[0]['itemCount'], 0)
        self.assertEqual(json.loads(self.call(f'/catalogs/{ROOT}/{UPLOAD}')['body'])['items'], [])
        for role in ('original', 'thumbnail'):
            self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}/items/{ITEM}/url', query={'role': role})['statusCode'], 404)
        self.assertEqual(self.fake.signed, [])

    def test_trashed_root_hidden_and_malformed_trash_fails_closed(self):
        self.fake.value['trash'] = [{'id': OWNER, 'name': 'Demo', 'state': 'deleting', 'itemIds': [ITEM], 'folderIds': [FOLDER]}]
        self.assertEqual(json.loads(self.call()['body']), [])
        self.assertEqual(self.call(f'/catalogs/{ROOT}/{UPLOAD}')['statusCode'], 404)
        self.fake.value['trash'][0]['state'] = 'bad'
        self.assertEqual(self.call()['statusCode'], 400)
        self.assertEqual(self.fake.signed, [])

    def test_catalog_creation_rank_does_not_resurrect_old_upload_on_edit(self):
        old_upload = OWNER
        old = dict(self.fake.value, id=old_upload, catalogCreatedAt=1)
        new = dict(self.fake.value, catalogCreatedAt=2)
        def fetch(**args):
            if args['Key'] == folder_security.KEY:
                return {'Body': io.BytesIO(json.dumps(self.fake.settings).encode())}
            return {'Body': io.BytesIO(json.dumps(old if old_upload in args['Key'] else new).encode())}
        with patch.object(self.fake, 'get_object', side_effect=fetch), patch.object(self.fake, 'list_objects_v2', return_value={'Contents': [
            {'Key': f'media-hub/catalogs/{ROOT}/{old_upload}.json', 'LastModified': 99},
            {'Key': f'media-hub/catalogs/{ROOT}/{UPLOAD}.json', 'LastModified': 2}]}):
            self.assertEqual(json.loads(self.call()['body'])[0]['id'], UPLOAD)
