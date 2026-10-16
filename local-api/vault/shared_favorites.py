"""Desktop bridge to the same owner favorites used by the phone API."""
import io
import json
from pathlib import Path
import tempfile

from .service import VaultError
import favorites
import folder_security
import reader


class MissingObject(Exception):
    response = {'Error': {'Code': 'NoSuchKey'}}


class FavoriteS3Bridge:
    def __init__(self, client, root):
        self.client = client
        self.root = root

    def head_object(self, *, Bucket, Key):
        value = self.client.head(Key)
        if value is None:
            raise MissingObject()
        return value

    def get_object(self, *, Bucket, Key):
        head = self.head_object(Bucket=Bucket, Key=Key)
        if head.get('ContentLength', 0) > 16 * 1024 ** 2:
            raise ValueError('Object too large')
        with tempfile.TemporaryDirectory(dir=self.root, prefix='favorites-read-') as folder:
            path = Path(folder) / 'data'
            self.client.download(Key, head.get('VersionId'), path)
            if path.stat().st_size > 16 * 1024 ** 2:
                raise ValueError('Object too large')
            return {'Body': io.BytesIO(path.read_bytes()), 'ETag': head.get('ETag')}

    def list_objects_v2(self, *, Bucket, Prefix, MaxKeys, ContinuationToken=None):
        args = ['--prefix', Prefix, '--max-keys', str(MaxKeys)]
        if ContinuationToken:
            args += ['--continuation-token', ContinuationToken]
        return self.client.call('list-objects-v2', *args)

    def put_object(self, *, Bucket, Key, Body, ContentType, ChecksumSHA256, IfMatch=None, IfNoneMatch=None):
        self.client.verify_private()
        with tempfile.TemporaryDirectory(dir=self.root, prefix='favorites-save-') as folder:
            path = Path(folder) / 'data'
            path.write_bytes(Body)
            path.chmod(0o600)
            self.client.put(path, Key, ChecksumSHA256, ContentType, etag=IfMatch)


def execute(uploads, body, token, write=False):
    destination = {'bucket', 'profile', 'region'}
    expected = destination | ({'reference', 'favorite'} if write else set())
    if set(body) != expected or not all(isinstance(body[k], str) and 0 < len(body[k]) <= 255 for k in destination):
        raise VaultError('invalid_request', 'お気に入りの接続先を確認してください。')
    bridge = FavoriteS3Bridge(uploads.client_factory(body['bucket'], body['profile'], body['region']), uploads.root)
    bucket = body['bucket']
    try:
        settings = folder_security.load(bridge, bucket)
        allowed = folder_security.grants(settings, token, 'desktop')
        cache = {}
        authorize = lambda ref: favorites.visible(bridge, bucket, ref, settings, allowed, reader.catalog, cache)
        if not write:
            return favorites.listing(bridge, bucket, authorize)
        status, result = favorites.update(bridge, bucket, {k: body[k] for k in ('reference', 'favorite')}, authorize)
        if status != 200:
            raise VaultError('not_found', '対象のフォルダを開き直してください。', status)
        return result
    except (ValueError, TypeError, KeyError):
        raise VaultError('invalid_request', 'お気に入り情報を確認できません。', 400)
