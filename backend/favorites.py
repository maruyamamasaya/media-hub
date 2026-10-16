"""Owner-scoped favorites with compare-and-swap updates. IDs only; no media names or decryption keys."""
import base64
import hashlib
import json
from app import valid_id

PREFIX = 'media-hub/favorites/'
FIELDS = {'space', 'rootId', 'catalogId', 'targetId', 'kind'}
MAX_RECORDS = 10000


def reference(value):
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise ValueError('Invalid favorite')
    if value['space'] not in ('normal', 'sealed') or value['kind'] not in ('folder', 'item'):
        raise ValueError('Invalid favorite')
    if not all(valid_id(value[k]) for k in ('rootId', 'catalogId', 'targetId')):
        raise ValueError('Invalid favorite')
    return value


def key(value):
    identity = reference(value).copy()
    if identity['space'] == 'normal':
        identity.pop('catalogId')  # Same normal target survives a new catalog revision.
    return PREFIX + hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest() + '.json'


def missing(exc):
    return getattr(exc, 'response', {}).get('Error', {}).get('Code') in ('NoSuchKey', '404', 'NotFound')


def visible(s3, bucket, value, settings, allowed, catalog_loader, cache):
    identity = (value['space'], value['rootId'], value['catalogId'])
    if identity not in cache:
        try:
            if value['space'] == 'sealed':
                s3.head_object(Bucket=bucket, Key=f"media-hub/encrypted-catalogs/{value['rootId']}/{value['catalogId']}.bin")
                cache[identity] = True  # Opaque target IDs are checked against decrypted catalogs by clients.
            else:
                import catalog_trash
                import folder_security
                catalog = catalog_trash.active(catalog_loader(s3, bucket, value['rootId'], value['catalogId']))
                cache[identity] = folder_security.visible(catalog, settings, allowed) if catalog else None
        except Exception as exc:
            if not missing(exc):
                raise
            cache[identity] = None
    catalog = cache[identity]
    if value['space'] == 'sealed':
        return catalog is True
    group = 'folders' if value['kind'] == 'folder' else 'items'
    return catalog is not None and any(item['id'] == value['targetId'] for item in catalog[group])


KEY = PREFIX + 'state.json'
MAX_BYTES = 4 * 1024 ** 2


def load(s3, bucket):
    try:
        result = s3.get_object(Bucket=bucket, Key=KEY)
    except Exception as exc:
        if not missing(exc):
            raise
        return {}, None
    stream = result['Body']
    try:
        data = stream.read(MAX_BYTES + 1)
    finally:
        stream.close()
    if len(data) > MAX_BYTES:
        raise ValueError('Favorite index too large')
    state = json.loads(data)
    if not isinstance(state, dict) or set(state) != {'schemaVersion', 'entries'} or state['schemaVersion'] != 1 or not isinstance(state['entries'], dict) or len(state['entries']) > MAX_RECORDS:
        raise ValueError('Invalid favorite state')
    for identity, ref in state['entries'].items():
        if key(reference(ref)) != identity:
            raise ValueError('Invalid favorite identity')
    if not result.get('ETag'):
        raise ValueError('Missing favorite revision')
    return state['entries'], result['ETag']


def listing(s3, bucket, authorize):
    entries, _ = load(s3, bucket)
    return [ref for ref in entries.values() if authorize(ref)]


def update(s3, bucket, body, authorize):
    if not isinstance(body, dict) or set(body) != {'reference', 'favorite'} or type(body['favorite']) is not bool:
        raise ValueError('Invalid favorite request')
    ref = reference(body['reference'])
    if not authorize(ref):
        return 404, {'error': 'Favorite target unavailable'}
    for _ in range(3):
        entries, etag = load(s3, bucket)
        if body['favorite']:
            entries[key(ref)] = ref
        else:
            entries.pop(key(ref), None)
        if len(entries) > MAX_RECORDS:
            return 413, {'error': 'Favorite limit exceeded'}
        data = json.dumps({'schemaVersion': 1, 'entries': entries}, sort_keys=True, separators=(',', ':')).encode()
        if len(data) > MAX_BYTES:
            return 413, {'error': 'Favorite index too large'}
        digest = base64.b64encode(hashlib.sha256(data).digest()).decode()
        condition = {'IfMatch': etag} if etag else {'IfNoneMatch': '*'}
        try:
            s3.put_object(Bucket=bucket, Key=KEY, Body=data, ContentType='application/json', ChecksumSHA256=digest, **condition)
            return 200, {'saved': True}
        except Exception as exc:
            code = getattr(exc, 'response', {}).get('Error', {}).get('Code')
            if code not in ('PreconditionFailed', 'ConditionalRequestConflict', '412', '409') and getattr(exc, 'code', '') != 'conflict':
                raise
    return 409, {'error': 'Favorites changed; retry'}
