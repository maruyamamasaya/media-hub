"""Owner-authenticated, read-only media-hub catalog and GET URL service."""
import json
import os
import re
import base64
import hashlib
from urllib.parse import unquote
from app import client, response, valid_id
import folder_security as privacy
import encrypted_reader
import catalog_trash
import usage_report
import favorites

from catalog_limits import MAX_CATALOG_BYTES, CATALOG_CHUNK_BYTES, MAX_CATALOG_RESPONSE_BYTES


def catalog(s3, bucket, root, upload):
    if not valid_id(root) or not valid_id(upload):
        raise ValueError('Invalid catalog')
    result = s3.get_object(Bucket=bucket, Key=f'media-hub/catalogs/{root}/{upload}.json')
    body = result['Body']
    try:
        raw = body.read(MAX_CATALOG_BYTES + 1)
    finally:
        body.close()
    if len(raw) > MAX_CATALOG_BYTES:
        raise ValueError('Catalog too large')
    value = json.loads(raw)
    if value.get('schemaVersion') != 1 or value.get('rootId') != root or value.get('id') != upload:
        raise ValueError('Invalid catalog identity')
    if not isinstance(value.get('name'), str) or not isinstance(value.get('folders'), list) or not isinstance(value.get('items'), list):
        raise ValueError('Invalid catalog')
    if len(value['items']) > 10000 or len(value['folders']) > 10000:
        raise ValueError('Catalog too large')
    ids = set()
    for folder in value['folders']:
        if not valid_id(folder.get('id')) or not isinstance(folder.get('name'), str) or folder['id'] in ids:
            raise ValueError('Invalid folder')
        ids.add(folder['id'])
    roots = [f for f in value['folders'] if f.get('parentId') is None]
    if len(roots) != 1:
        raise ValueError('Invalid root folder')
    parents = {f['id']: f.get('parentId') for f in value['folders']}
    for folder in value['folders']:
        seen, node = set(), folder['id']
        while node is not None:
            if node in seen or node not in parents:
                raise ValueError('Invalid folder tree')
            seen.add(node)
            node = parents[node]
    item_ids = set()
    for item in value['items']:
        asset, sha = item.get('id'), item.get('sha256')
        if not valid_id(asset) or asset in item_ids or not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha):
            raise ValueError('Invalid media identity')
        if item.get('objectKey') != f'media-hub/originals/{asset}/{sha}' or item.get('folderId') not in ids:
            raise ValueError('Invalid media location')
        if not isinstance(item.get('name'), str) or not isinstance(item.get('mimeType'), str) or type(item.get('byteSize')) is not int or item['byteSize'] <= 0:
            raise ValueError('Invalid media metadata')
        version = item.get('versionId')
        if version is not None and (not isinstance(version, str) or not version or len(version) > 1024):
            raise ValueError('Invalid version')
        thumb = item.get('thumbnailKey')
        if thumb is not None and thumb != f'media-hub/thumbnails/{asset}/{sha}.png':
            raise ValueError('Invalid thumbnail location')
        item_ids.add(asset)
    catalog_trash.validate(value)
    return value


def public_catalog(value):
    return {'id': value['id'], 'rootId': value['rootId'], 'name': value['name'], 'folders': [{k: f.get(k) for k in ('id', 'name', 'parentId')} | {'isLocked': bool(f.get('isLocked'))} for f in value['folders']],
            'items': [{k: i[k] for k in ('id', 'name', 'folderId', 'byteSize', 'sha256', 'mimeType')} | {'hasThumbnail': bool(i.get('thumbnailKey'))} for i in value['items']]}


def handler(event, context):
    owner, bucket = os.getenv('OWNER_SUB', ''), os.getenv('BUCKET', '')
    if not valid_id(owner) or not bucket:
        return response(503, {'error': 'Service configuration incomplete'})
    claims = event.get('requestContext', {}).get('authorizer', {}).get('jwt', {}).get('claims', {})
    if not claims.get('sub'):
        return response(401, {'error': 'Authentication required'})
    if claims['sub'] != owner:
        return response(403, {'error': 'Owner only'})
    method = event.get('requestContext', {}).get('http', {}).get('method')
    path = unquote(event.get('rawPath', ''))
    if method != 'GET' and not (method == 'POST' and path in ('/folder-unlock', '/favorites')):
        return response(405, {'error': 'Read only'})
    try:
        s3 = client()
        if path == '/usage':
            value = usage_report.load(s3, bucket)
            return response(200, value) if value is not None else response(404, {'error': 'Refresh usage on Mac first'})
        if path.startswith('/encrypted-'):
            status, value = encrypted_reader.handle(s3, bucket, path)
            return response(status, value)
        settings = privacy.load(s3, bucket)
        def reply(status, body):
            result = response(status, body)
            result['headers']['X-Folder-Lock-Revision'] = settings['revision']
            return result
        headers = {key.lower(): value for key, value in event.get('headers', {}).items()}
        grant = headers.get('x-folder-unlock', '')
        allowed = privacy.grants(settings, grant, owner)
        if path == '/favorites':
            cache = {}
            authorize = lambda ref: favorites.visible(s3, bucket, ref, settings, allowed, catalog, cache)
            if method == 'GET':
                return reply(200, favorites.listing(s3, bucket, authorize))
            raw = event.get('body', '')
            if event.get('isBase64Encoded'):
                raw = base64.b64decode(raw).decode()
            if len(raw) > 2048:
                return reply(400, {'error': 'Invalid favorite request'})
            status, value = favorites.update(s3, bucket, json.loads(raw), authorize)
            return reply(status, value)
        if path == '/folder-unlock':
            if method != 'POST':
                return reply(405, {'error': 'POST required'})
            raw = event.get('body', '')
            if event.get('isBase64Encoded'):
                raw = base64.b64decode(raw).decode()
            if len(raw) > 2048:
                return reply(400, {'error': 'Invalid request'})
            body = json.loads(raw)
            if not isinstance(body, dict) or set(body) != {'password'}:
                return reply(400, {'error': 'Invalid request'})
            try:
                result = privacy.unlock(settings, body['password'], owner, grant)
            except ValueError:
                return reply(403, {'error': 'Cannot unlock'})
            return reply(200, result)
        if path == '/library':
            latest, token = {}, None
            for _ in range(10):
                args = {'Bucket': bucket, 'Prefix': 'media-hub/catalogs/', 'MaxKeys': 1000}
                if token:
                    args['ContinuationToken'] = token
                listing = s3.list_objects_v2(**args)
                for entry in listing.get('Contents', []):
                    parts = entry['Key'].split('/')
                    if len(parts) != 4 or not valid_id(parts[2]) or not parts[3].endswith('.json') or not valid_id(parts[3][:-5]):
                        continue
                    value = catalog(s3, bucket, parts[2], parts[3][:-5])
                    modified = entry['LastModified']
                    rank = value.get('catalogCreatedAt', modified.timestamp() if hasattr(modified, 'timestamp') else modified)
                    if parts[2] not in latest or rank > latest[parts[2]]['rank']:
                        latest[parts[2]] = {'rank': rank, 'value': value}

                token = listing.get('NextContinuationToken')
                if not token:
                    break
            if token or len(latest) > 50:
                return reply(413, {'error': 'Catalog index limit exceeded'})
            roots = []
            for root, entry in latest.items():
                value = entry['value']
                upload = value['id']
                value = catalog_trash.active(value)
                value = privacy.visible(value, settings, allowed) if value is not None else None
                if value is None:
                    continue
                roots.append({'id': upload, 'rootId': root, 'name': value['name'], 'itemCount': len(value['items']),
                              'byteSize': sum(i['byteSize'] for i in value['items'])})
            return reply(200, sorted(roots, key=lambda r: r['name']))
        parts = path.strip('/').split('/')
        if len(parts) not in (3, 6) or parts[0] != 'catalogs':
            return reply(404, {'error': 'Not found'})
        value = catalog_trash.active(catalog(s3, bucket, parts[1], parts[2]))
        value = privacy.visible(value, settings, allowed) if value is not None else None
        if value is None:
            return reply(404, {'error': 'Not found'})
        if len(parts) == 3:
            ids = (event.get('queryStringParameters') or {}).get('thumbnailIds')
            if ids is not None:
                requested = ids.split(',')
                if not 1 <= len(requested) <= 60 or len(set(requested)) != len(requested) or not all(valid_id(i) for i in requested):
                    raise ValueError('Invalid thumbnail batch')
                items = {i['id']: i for i in value['items']}
                # Validate the whole batch before signing anything, after visibility filtering.
                if any(i not in items or not items[i].get('thumbnailKey') for i in requested):
                    return reply(404, {'error': 'Preview unavailable'})
                urls = {}
                for identity in requested:
                    params = {'Bucket': bucket, 'Key': items[identity]['thumbnailKey'], 'ResponseCacheControl': 'private, no-store'}
                    urls[identity] = s3.generate_presigned_url('get_object', Params=params, ExpiresIn=300, HttpMethod='GET')
                return reply(200, {'urls': urls, 'expiresIn': 300})
            public = public_catalog(value)
            query = event.get('queryStringParameters') or {}
            if 'catalogOffset' in query:
                # Filter permissions on EVERY chunk. A digest binds chunks to one
                # exact public projection, including trash and lock visibility.
                offset_text = query['catalogOffset']
                if not isinstance(offset_text, str) or not re.fullmatch(r'0|[1-9][0-9]{0,8}', offset_text):
                    raise ValueError('Invalid catalog offset')
                raw = json.dumps(public, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
                if len(raw) > MAX_CATALOG_RESPONSE_BYTES:
                    raise ValueError('Catalog response too large')
                digest = hashlib.sha256(raw).hexdigest()
                offset = int(offset_text)
                if offset >= len(raw) or offset % CATALOG_CHUNK_BYTES:
                    raise ValueError('Invalid catalog offset')
                if offset and query.get('catalogDigest') != digest:
                    return reply(409, {'error': 'Catalog changed; reload'})
                chunk = raw[offset:offset + CATALOG_CHUNK_BYTES]
                end = offset + len(chunk)
                return reply(200, {'data': base64.b64encode(chunk).decode('ascii'),
                                   'offset': offset, 'totalBytes': len(raw), 'sha256': digest,
                                   'nextOffset': end if end < len(raw) else None})
            # Legacy clients retain small responses; never exceed Lambda's
            # buffered response limit after nested JSON escaping.
            result = reply(200, public)
            if len(json.dumps(result).encode('utf-8')) > 5 * 1024 * 1024:
                return reply(413, {'error': 'Catalog requires chunked download; update app'})
            return result
        if parts[3] != 'items' or parts[5] != 'url' or not valid_id(parts[4]):
            return reply(404, {'error': 'Not found'})
        item = next((i for i in value['items'] if i['id'] == parts[4]), None)
        if item is None:
            return reply(404, {'error': 'Not found'})
        role = (event.get('queryStringParameters') or {}).get('role', 'original')
        if role not in ('original', 'thumbnail'):
            raise ValueError('Invalid role')
        key = item['objectKey'] if role == 'original' else item.get('thumbnailKey')
        if not key:
            return reply(404, {'error': 'Preview unavailable'})
        params = {'Bucket': bucket, 'Key': key, 'ResponseCacheControl': 'private, no-store'}
        if role == 'original' and item.get('versionId'):
            params['VersionId'] = item['versionId']
        url = s3.generate_presigned_url('get_object', Params=params, ExpiresIn=300, HttpMethod='GET')
        return reply(200, {'url': url, 'expiresIn': 300})
    except (ValueError, TypeError, KeyError, UnicodeError):
        return response(400, {'error': 'Invalid catalog or request'})
    except Exception:
        return response(502, {'error': 'Storage operation failed'})
