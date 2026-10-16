import base64
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import favorites
import reader
import folder_security
from test_reader import Fake, OWNER, ROOT, UPLOAD, FOLDER, ITEM


class StorageError(Exception):
    def __init__(self, code):
        self.response = {'Error': {'Code': code}}


class FavoriteCloud(Fake):
    def __init__(self):
        super().__init__()
        self.state = None
        self.revision = 0
        self.before_put = None
        self.writes = 0

    def get_object(self, **args):
        if args['Key'] != favorites.KEY:
            return super().get_object(**args)
        if self.state is None:
            raise StorageError('NoSuchKey')
        return {'Body': io.BytesIO(self.state), 'ETag': str(self.revision)}

    def put_object(self, **args):
        if self.before_put:
            callback, self.before_put = self.before_put, None
            callback()
        if args.get('IfMatch') != (str(self.revision) if self.state is not None else None) or (self.state is not None and 'IfNoneMatch' in args):
            raise StorageError('PreconditionFailed')
        assert args['Key'] == favorites.KEY
        assert args['ContentType'] == 'application/json'
        assert base64.b64encode(hashlib.sha256(args['Body']).digest()).decode() == args['ChecksumSHA256']
        self.state = args['Body']; self.revision += 1; self.writes += 1

    def head_object(self, **args):
        return {'ContentLength': 12}


class FavoritesTests(unittest.TestCase):
    def setUp(self):
        self.cloud = FavoriteCloud()
        self.environment = patch.dict(os.environ, {'BUCKET': 'test-bucket', 'OWNER_SUB': OWNER})
        self.environment.start(); self.addCleanup(self.environment.stop)
        self.client = patch('reader.client', return_value=self.cloud)
        self.client.start(); self.addCleanup(self.client.stop)
        self.ref = dict(space='normal', rootId=ROOT, catalogId=UPLOAD, targetId=ITEM, kind='item')

    def call(self, method='GET', body=None, owner=OWNER, headers=None):
        return reader.handler({'rawPath': '/favorites', 'body': json.dumps(body) if body is not None else '', 'headers': headers or {}, 'requestContext': {'http': {'method': method}, 'authorizer': {'jwt': {'claims': {'sub': owner} if owner else {}}}}}, None)

    def test_owner_only_roundtrip_no_names_and_idempotent_remove(self):
        self.assertEqual(self.call()['body'], '[]')
        for owner, status in [(None, 401), (ROOT, 403)]:
            self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': True}, owner)['statusCode'], status)
        self.assertEqual(self.cloud.writes, 0)
        self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': True})['statusCode'], 200)
        self.assertEqual(json.loads(self.call()['body']), [self.ref])
        self.assertNotIn(b'sample.jpg', self.cloud.state)
        for _ in range(2):
            self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': False})['statusCode'], 200)
        self.assertEqual(self.call()['body'], '[]')

    def test_two_device_conflict_merges_different_targets(self):
        other = self.ref | dict(targetId=FOLDER, kind='folder')
        def other_device():
            self.assertEqual(favorites.update(self.cloud, 'test-bucket', {'reference': other, 'favorite': True}, lambda _: True)[0], 200)
        self.cloud.before_put = other_device
        self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': True})['statusCode'], 200)
        self.assertEqual({v['targetId'] for v in json.loads(self.call()['body'])}, {FOLDER, ITEM})

    def test_hidden_and_trashed_targets_are_filtered_and_cannot_be_written(self):
        self.call('POST', {'reference': self.ref, 'favorite': True})
        self.cloud.settings['locks'] = [folder_security.make_lock(ROOT, FOLDER, '012345')]
        self.assertEqual(self.call()['body'], '[]')
        self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': False})['statusCode'], 404)
        grant = folder_security.unlock(self.cloud.settings, '012345', OWNER)['token']
        headers = {'X-Folder-Unlock': grant}
        self.assertEqual(json.loads(self.call(headers=headers)['body']), [self.ref])
        self.cloud.settings['locks'] = []
        self.cloud.value['trash'] = [{'id': ROOT, 'name': 'deleted', 'state': 'trashed', 'itemIds': [ITEM], 'folderIds': []}]
        self.assertEqual(self.call()['body'], '[]')
        self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': True})['statusCode'], 404)
        self.cloud.value.pop('trash')
        self.assertEqual(json.loads(self.call()['body']), [self.ref])

    def test_rejects_invalid_targets_and_corrupt_state(self):
        for body in [{'reference': self.ref, 'favorite': 'yes'}, {'reference': self.ref | {'targetId': '../secret'}, 'favorite': True}, {'reference': self.ref | {'name': 'leak'}, 'favorite': True}]:
            self.assertEqual(self.call('POST', body)['statusCode'], 400)
        self.assertEqual(self.cloud.writes, 0)
        self.cloud.state = b'{}'
        self.assertEqual(self.call()['statusCode'], 400)
        self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': True})['statusCode'], 400)
        self.assertEqual(self.cloud.writes, 0)

    def test_persistent_conflict_never_reports_success(self):
        with patch.object(self.cloud, 'put_object', side_effect=StorageError('PreconditionFailed')) as put:
            self.assertEqual(self.call('POST', {'reference': self.ref, 'favorite': True})['statusCode'], 409)
            self.assertEqual(put.call_count, 3)

    def test_normal_identity_survives_catalog_revision_but_sealed_scope_does_not(self):
        self.assertEqual(favorites.key(self.ref), favorites.key(self.ref | {'catalogId': ROOT}))
        sealed = self.ref | {'space': 'sealed'}
        self.assertNotEqual(favorites.key(sealed), favorites.key(sealed | {'catalogId': ROOT}))
        self.assertEqual(self.call('POST', {'reference': sealed, 'favorite': True})['statusCode'], 200)
        self.assertEqual(json.loads(self.call()['body']), [sealed])
