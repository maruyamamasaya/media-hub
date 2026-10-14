"""Shared catalog trash projection; metadata stays in private catalog JSON."""
import copy
import uuid
import math


def validate(value):
    created = value.get('catalogCreatedAt')
    if created is not None and (type(created) not in (int, float) or not math.isfinite(created) or created <= 0):
        raise ValueError('Invalid catalog creation time')
    entries = value.get('trash', [])
    if not isinstance(entries, list) or len(entries) > 10000:
        raise ValueError('Invalid trash')
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict) or entry.get('state') not in ('trashed', 'deleting', 'purged'):
            raise ValueError('Invalid trash')
        identity = entry.get('id')
        if str(uuid.UUID(identity)) != identity or identity in seen or not isinstance(entry.get('name'), str):
            raise ValueError('Invalid trash')
        seen.add(identity)
        for field in ('itemIds', 'folderIds'):
            if not isinstance(entry.get(field), list) or len(entry[field]) > 10000:
                raise ValueError('Invalid trash')
            for identifier in entry[field]:
                if str(uuid.UUID(identifier)) != identifier:
                    raise ValueError('Invalid trash')
    return entries


def active(value):
    entries = validate(value)
    folders = {i for e in entries for i in e['folderIds']}
    items = {i for e in entries for i in e['itemIds']}
    result = copy.deepcopy(value)
    result['folders'] = [f for f in value['folders'] if f['id'] not in folders]
    result['items'] = [i for i in value['items'] if i['id'] not in items and i['folderId'] not in folders]
    if not any(f.get('parentId') is None for f in result['folders']):
        return None
    return result
