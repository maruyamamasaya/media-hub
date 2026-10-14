"""Folder password verifiers, short-lived grants and catalog pruning. No logging."""
import base64
import hashlib
import hmac
import json
import secrets
import time
import uuid

KEY = 'media-hub/folder-locks/settings.json'
ITERATIONS = 600000
MAX_LOCKS = 10
TTL = 300


def valid_uuid(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def empty_settings():
    return dict(schemaVersion=1, revision=str(uuid.uuid4()), signingKey=secrets.token_hex(32), locks=[])


def validate(value):
    if value.get('schemaVersion') != 1 or not valid_uuid(value.get('revision')):
        raise ValueError('Invalid lock settings')
    secret = value.get('signingKey', '')
    if not isinstance(secret, str) or len(secret) != 64:
        raise ValueError('Invalid lock settings')
    bytes.fromhex(secret)
    locks = value.get('locks')
    if not isinstance(locks, list) or len(locks) > MAX_LOCKS:
        raise ValueError('Invalid lock settings')
    seen = set()
    for lock in locks:
        if not valid_uuid(lock.get('folderId')) or not valid_uuid(lock.get('rootId')) or lock['folderId'] in seen:
            raise ValueError('Invalid lock settings')
        for field, size in [('salt', 32), ('verifier', 64)]:
            if not isinstance(lock.get(field), str) or len(lock[field]) != size:
                raise ValueError('Invalid lock settings')
            bytes.fromhex(lock[field])
        seen.add(lock['folderId'])
    return value


def password_bytes(password):
    if not isinstance(password, str) or not ((len(password) == 6 and password.isascii() and password.isdigit()) or 8 <= len(password) <= 128):
        raise ValueError('Invalid folder credential')
    return password.encode('utf-8')


def make_lock(root, folder, password):
    if not valid_uuid(root) or not valid_uuid(folder):
        raise ValueError('Invalid folder identity')
    if not isinstance(password, str) or len(password) != 6 or not password.isascii() or not password.isdigit():
        raise ValueError('Folder PIN must contain exactly six ASCII digits')
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac('sha256', password_bytes(password), bytes.fromhex(salt), ITERATIONS).hex()
    return dict(rootId=root, folderId=folder, salt=salt, verifier=digest)


def load(s3, bucket):
    result = s3.get_object(Bucket=bucket, Key=KEY)
    body = result['Body']
    try:
        raw = body.read(65537)
    finally:
        body.close()
    if len(raw) > 65536:
        raise ValueError('Invalid lock settings')
    return validate(json.loads(raw))


def encode(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip('=')


def decode(value):
    return base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))


def grants(settings, token, owner, now=None):
    now = time.time() if now is None else now
    if not isinstance(token, str) or len(token) > 4096:
        return set()
    try:
        payload, signature = token.split('.')
        expected = hmac.new(bytes.fromhex(settings['signingKey']), payload.encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(expected, decode(signature)):
            return set()
        value = json.loads(decode(payload))
        if value['owner'] != owner or value['revision'] != settings['revision'] or not now < value['expires'] <= now + TTL + 1:
            return set()
        allowed = {lock['folderId'] for lock in settings['locks']}
        ids = value['folders']
        if not isinstance(ids, list) or any(folder not in allowed for folder in ids):
            return set()
        return set(ids)
    except (ValueError, KeyError, TypeError):
        return set()


def unlock(settings, password, owner, previous='', now=None):
    now = time.time() if now is None else now
    raw = password_bytes(password)
    matched = set()
    # Check every configured verifier; do not expose names or which entry failed.
    for lock in settings['locks']:
        digest = hashlib.pbkdf2_hmac('sha256', raw, bytes.fromhex(lock['salt']), ITERATIONS).hex()
        if hmac.compare_digest(digest, lock['verifier']):
            matched.add(lock['folderId'])
    if not matched:
        raise ValueError('Cannot unlock')
    matched |= grants(settings, previous, owner, now)
    payload = encode(json.dumps(dict(owner=owner, revision=settings['revision'], expires=int(now) + TTL,
                                    folders=sorted(matched)), separators=(',', ':')).encode())
    signature = encode(hmac.new(bytes.fromhex(settings['signingKey']), payload.encode(), hashlib.sha256).digest())
    return dict(token=payload + '.' + signature, expiresIn=TTL)


def visible(value, settings, allowed):
    protected = {lock['folderId'] for lock in settings['locks'] if lock['rootId'] == value['rootId']}
    parents = {folder['id']: folder.get('parentId') for folder in value['folders']}
    root = next(folder['id'] for folder in value['folders'] if folder.get('parentId') is None)
    def accessible(folder):
        seen = set()
        while folder is not None:
            if folder in seen or folder not in parents:
                return False
            if folder in protected and folder not in allowed:
                return False
            seen.add(folder)
            folder = parents[folder]
        return True
    if not accessible(root):
        return None
    folders = [folder | {'isLocked': folder['id'] in protected} for folder in value['folders'] if accessible(folder['id'])]
    ids = {folder['id'] for folder in folders}
    return value | dict(folders=folders, items=[item for item in value['items'] if item['folderId'] in ids])
