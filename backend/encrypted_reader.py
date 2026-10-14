"""Owner-only opaque ciphertext index/URLs. This service never receives decryption keys."""
from app import valid_id


def handle(s3, bucket, path):
    if path == '/encrypted-library':
        results, token = [], None
        for _ in range(20):
            args = {'Bucket': bucket, 'Prefix': 'media-hub/encrypted-catalogs/', 'MaxKeys': 1000}
            if token:
                args['ContinuationToken'] = token
            value = s3.list_objects_v2(**args)
            for entry in value.get('Contents', []):
                parts = entry['Key'].split('/')
                if len(parts) == 4 and parts[3].endswith('.bin') and valid_id(parts[2]) and valid_id(parts[3][:-4]):
                    results.append({'id': parts[3][:-4], 'keyID': parts[2], 'cipherBytes': entry['Size']})
            token = value.get('NextContinuationToken')
            if not token:
                break
        if token or len(results) > 100:
            return 413, {'error': 'Encrypted catalog index limit exceeded'}
        return 200, sorted(results, key=lambda entry: entry['id'])
    parts = path.strip('/').split('/')
    if len(parts) == 4 and parts[0] == 'encrypted-catalogs' and parts[3] == 'url' and all(valid_id(v) for v in parts[1:3]):
        key = f'media-hub/encrypted-catalogs/{parts[1]}/{parts[2]}.bin'
    elif len(parts) == 5 and parts[0] == 'encrypted-objects' and parts[4] == 'url' and all(valid_id(v) for v in parts[1:4]):
        # Object scope is the same upload's encrypted catalog, not a client-supplied S3 key.
        s3.head_object(Bucket=bucket, Key=f'media-hub/encrypted-catalogs/{parts[1]}/{parts[2]}.bin')
        key = f'media-hub/encrypted-objects/{parts[1]}/{parts[2]}/{parts[3]}.bin'
    else:
        return 400, {'error': 'Invalid encrypted request'}
    metadata = s3.head_object(Bucket=bucket, Key=key)
    params = {'Bucket': bucket, 'Key': key, 'ResponseCacheControl': 'private, no-store', 'ResponseContentType': 'application/octet-stream'}
    if metadata.get('VersionId'):
        params['VersionId'] = metadata['VersionId']
    url = s3.generate_presigned_url('get_object', Params=params, ExpiresIn=300, HttpMethod='GET')
    return 200, {'url': url, 'expiresIn': 300}
