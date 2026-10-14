"""A bounded aggregate report; never return object keys or personal metadata."""
import json
import math
from datetime import datetime, date

KEY = 'media-hub/usage/latest.json'
MAX_BYTES = 128 * 1024


def validate(value):
    def number(v):
        return type(v) in (int, float) and math.isfinite(v) and 0 <= v <= 10**18
    sizes = ('storageBytes', 'currentBytes', 'previousBytes', 'normalBytes', 'encryptedBytes', 'thumbnailBytes', 'metadataBytes')
    fields = {'schemaVersion', 'updatedAt', 'region', *sizes, 'storageEstimateYen', 'targetYen', 'exchangeRate', 'taxMultiplier', 'rateUSDPerGiB', 'history', 'notes'}
    if not isinstance(value, dict) or not fields <= value.keys() or value.keys() - fields - {'budget'} or value['schemaVersion'] != 1:
        raise ValueError('Invalid usage report')
    if not isinstance(value['updatedAt'], str) or len(value['updatedAt']) > 40 or datetime.fromisoformat(value['updatedAt'].replace('Z', '+00:00')).tzinfo is None:
        raise ValueError('Invalid timestamp')
    if not isinstance(value['region'], str) or len(value['region']) > 40:
        raise ValueError('Invalid region')
    if any(type(value[k]) is not int or not number(value[k]) for k in sizes):
        raise ValueError('Invalid size')
    if value['currentBytes'] + value['previousBytes'] != value['storageBytes'] or sum(value[k] for k in ('normalBytes', 'encryptedBytes', 'thumbnailBytes', 'metadataBytes', 'previousBytes')) != value['storageBytes']:
        raise ValueError('Invalid totals')
    for k in ('targetYen', 'exchangeRate', 'taxMultiplier', 'rateUSDPerGiB'):
        if not number(value[k]):
            raise ValueError('Invalid estimate')
    if value['storageEstimateYen'] is not None and not number(value['storageEstimateYen']):
        raise ValueError('Invalid estimate')
    history = value['history']
    if not isinstance(history, list) or not 1 <= len(history) <= 90:
        raise ValueError('Invalid history')
    previous = ''
    for point in history:
        if not isinstance(point, dict) or set(point) != {'date', 'storageBytes', 'storageEstimateYen'}:
            raise ValueError('Invalid point')
        if not isinstance(point['date'], str) or date.fromisoformat(point['date']).isoformat() != point['date'] or point['date'] <= previous:
            raise ValueError('Invalid date')
        previous = point['date']
        if type(point['storageBytes']) is not int or not number(point['storageBytes']) or (point['storageEstimateYen'] is not None and not number(point['storageEstimateYen'])):
            raise ValueError('Invalid point')
    if not isinstance(value['notes'], list) or len(value['notes']) > 10 or any(not isinstance(n, str) or len(n) > 300 for n in value['notes']):
        raise ValueError('Invalid notes')
    budget = value.get('budget')
    if budget is not None:
        if not isinstance(budget, dict) or set(budget) != {'limitUSD', 'actualUSD', 'forecastUSD', 'notificationCount', 'recipientCount'}:
            raise ValueError('Invalid budget')
        if any(not number(budget[k]) for k in ('limitUSD', 'actualUSD', 'notificationCount', 'recipientCount')) or (budget['forecastUSD'] is not None and not number(budget['forecastUSD'])):
            raise ValueError('Invalid budget')
        if any(type(budget[k]) is not int for k in ('notificationCount', 'recipientCount')):
            raise ValueError('Invalid budget')
    elif 'budget' in value:
        raise ValueError('Invalid budget')
    return value


def load(s3, bucket):
    try:
        result = s3.get_object(Bucket=bucket, Key=KEY)
    except Exception as exc:
        if getattr(exc, 'response', {}).get('Error', {}).get('Code') in ('NoSuchKey', '404'):
            return None
        raise
    body = result['Body']
    try:
        raw = body.read(MAX_BYTES + 1)
    finally:
        body.close()
    if len(raw) > MAX_BYTES:
        raise ValueError('Report too large')
    return validate(json.loads(raw))
