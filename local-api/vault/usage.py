"""Explicit refresh only. Aggregate media-hub versions, no original downloads."""
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from .folder_upload import S3CLI, atomic_json
from .service import VaultError
import usage_report

JST = timezone(timedelta(hours=9))


class Usage:
    def __init__(self, root, client_factory=S3CLI):
        self.root = Path(root) / 'usage'
        self.root.mkdir(exist_ok=True)
        if os.name == 'posix':
            self.root.chmod(0o700)
        self.client_factory = client_factory
        self.lock = threading.Lock()
        self.activity_lock = threading.Lock()

    def activity(self, body):
        path = self.destination(body).with_suffix('.activity.json')
        with self.activity_lock:
            return json.loads(path.read_text()) if path.exists() else []

    def record(self, body, requests=0, received_bytes=0):
        path = self.destination(body).with_suffix('.activity.json')
        with self.activity_lock:
            values = json.loads(path.read_text()) if path.exists() else []
            day = datetime.now(JST).date().isoformat()
            value = next((v for v in values if v['date'] == day), {'date': day, 'requests': 0, 'receivedBytes': 0, 'videoStarts': 0})
            value['requests'] += max(0, requests)
            value['receivedBytes'] += max(0, received_bytes)
            values = sorted([v for v in values if v['date'] != day] + [value], key=lambda v: v['date'])[-90:]
            atomic_json(path, values)
            if os.name == 'posix':
                path.chmod(0o600)

    def client(self, bucket, profile, region):
        body = {'bucket': bucket, 'profile': profile, 'region': region}
        return S3CLI(bucket, profile, region, recorder=lambda **values: self.record(body, **values))

    def destination(self, body):
        if set(body) != {'bucket', 'profile', 'region'} or any(not isinstance(v, str) or not v.strip() for v in body.values()):
            raise VaultError('invalid_request', '保存先を確認してください。')
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', body['bucket']) or not re.fullmatch(r'[\w-]+', body['region']) or body['profile'].startswith('-'):
            raise VaultError('invalid_request', '保存先を確認してください。')
        identity = hashlib.sha256(json.dumps([body['bucket'], body['region'], body['profile']]).encode()).hexdigest()
        return self.root / (identity + '.json')

    def cached(self, body):
        path = self.destination(body)
        if not path.exists():
            raise VaultError('not_found', 'Macで「AWSから更新」を押すと集計が始まります。', 404)
        return usage_report.validate(json.loads(path.read_text()))

    def budget(self, client):
        def call(service, operation, *args):
            result = subprocess.run(['aws', *client.options, service, operation, *args], capture_output=True, text=True, timeout=15)
            if result.returncode:
                raise ValueError('Budget unavailable')
            return json.loads(result.stdout)
        account = call('sts', 'get-caller-identity')['Account']
        args = ['--account-id', account, '--budget-name', 'Monthly-10USD-Alert']
        value = call('budgets', 'describe-budget', *args)['Budget']
        if value['BudgetLimit']['Unit'] != 'USD' or value.get('TimeUnit') != 'MONTHLY':
            raise ValueError('Budget units')
        actual = value['CalculatedSpend']['ActualSpend']
        forecast = value['CalculatedSpend'].get('ForecastedSpend')
        if actual['Unit'] != 'USD' or (forecast and forecast['Unit'] != 'USD'):
            raise ValueError('Budget units')
        notices = call('budgets', 'describe-notifications-for-budget', *args)['Notifications']
        recipients = set()
        for notice in notices:
            subscribers = call('budgets', 'describe-subscribers-for-notification', *args, '--notification', json.dumps(notice))['Subscribers']
            recipients.update((s['SubscriptionType'], s['Address']) for s in subscribers)
        return {'limitUSD': float(value['BudgetLimit']['Amount']), 'actualUSD': float(actual['Amount']),
                'forecastUSD': float(forecast['Amount']) if forecast else None, 'notificationCount': len(notices), 'recipientCount': len(recipients)}

    def refresh(self, body):
        path = self.destination(body)
        if not self.lock.acquire(blocking=False):
            raise VaultError('conflict', '集計中です。少し待って再試行してください。', 409)
        try:
            client = self.client_factory(body['bucket'], body['profile'], body['region'])
            client.timeout = 15
            client.verify_private()
            # Get the shared history and its ETag before counting; never overwrite another refresh.
            head = client.head(usage_report.KEY)
            previous = None
            if head:
                if head['ContentLength'] > usage_report.MAX_BYTES:
                    raise VaultError('integrity', '集計情報を確認できません。', 409)
                with tempfile.TemporaryDirectory() as temp:
                    target = Path(temp) / 'report.json'
                    client.download(usage_report.KEY, head.get('VersionId'), target)
                    previous = usage_report.validate(json.loads(target.read_text()))
            totals = dict.fromkeys(('currentBytes', 'previousBytes', 'normalBytes', 'encryptedBytes', 'thumbnailBytes', 'metadataBytes'), 0)
            standard = True
            key_marker = version_marker = None
            deadline = time.monotonic() + 60
            for _ in range(1000):
                if time.monotonic() >= deadline:
                    raise VaultError('cloud_error', '集計に時間がかかっています。手動で再試行してください。', 502)
                args = ['--prefix', 'media-hub/', '--no-paginate', '--max-keys', '1000']
                if key_marker:
                    args += ['--key-marker', key_marker]
                if version_marker:
                    args += ['--version-id-marker', version_marker]
                page = client.call('list-object-versions', *args)
                for item in page.get('Versions', []):
                    if not item['Key'].startswith('media-hub/'):
                        raise ValueError('Unexpected prefix')
                    amount = item['Size']
                    if type(amount) is not int or amount < 0:
                        raise ValueError('Invalid size')
                    standard &= item.get('StorageClass', 'STANDARD') == 'STANDARD'
                    if item['IsLatest']:
                        totals['currentBytes'] += amount
                        key = item['Key']
                        category = 'normalBytes' if key.startswith('media-hub/originals/') else 'encryptedBytes' if key.startswith('media-hub/encrypted-objects/') else 'thumbnailBytes' if key.startswith('media-hub/thumbnails/') else 'metadataBytes'
                        totals[category] += amount
                    else:
                        totals['previousBytes'] += amount
                if not page.get('IsTruncated'):
                    break
                new_marker = (page.get('NextKeyMarker'), page.get('NextVersionIdMarker'))
                if not new_marker[0] or new_marker == (key_marker, version_marker):
                    raise ValueError('Invalid pagination')
                key_marker, version_marker = new_marker
            else:
                raise VaultError('too_large', '集計上限を超えました。', 413)
            now = datetime.now(JST)
            amount = totals['currentBytes'] + totals['previousBytes']
            estimate = round(amount / 1024**3 * 0.025 * 150 * 1.1, 2) if standard and body['region'] == 'ap-northeast-1' else None
            point = {'date': now.date().isoformat(), 'storageBytes': amount, 'storageEstimateYen': estimate}
            history = [p for p in (previous or {}).get('history', []) if p['date'] < point['date']][-89:] + [point]
            value = {'schemaVersion': 1, 'updatedAt': now.isoformat(timespec='seconds'), 'region': body['region'], **totals,
                     'storageBytes': amount, 'storageEstimateYen': estimate, 'targetYen': 2000, 'exchangeRate': 150,
                     'taxMultiplier': 1.1, 'rateUSDPerGiB': 0.025, 'history': history,
                     'notes': ['S3のmedia-hub/配下・旧版とごみ箱、配布コードを含む集計。未完了の分割送信と削除マーカーは含みません。',
                               '保存費は現在量を1か月保持する試算。転送・API等、無料枠・割引は含みません。確定請求ではありません。',
                               '転送量は各端末が記録した受信量を参照。AWSの請求転送量は未取得です。']}
            try:
                value['budget'] = self.budget(client)
            except (ValueError, KeyError, OSError, subprocess.SubprocessError):
                value['notes'].append('既存予算は取得できませんでした。権限・AWSへの接続を確認してください。')
            usage_report.validate(value)
            with tempfile.TemporaryDirectory() as temp:
                target = Path(temp) / 'report.json'
                raw = json.dumps(value, ensure_ascii=False).encode()
                target.write_bytes(raw)
                digest = base64.b64encode(hashlib.sha256(raw).digest()).decode()
                client.put(target, usage_report.KEY, digest, 'application/json', etag=head.get('ETag') if head else None)
                remote = client.head(usage_report.KEY)
                if not remote or remote.get('ContentLength') != len(raw) or remote.get('ChecksumSHA256') != digest:
                    raise VaultError('integrity', '共有した集計の保存を確認できません。再試行してください。', 502)
            atomic_json(path, value)
            if os.name == 'posix':
                path.chmod(0o600)
            return value
        except subprocess.TimeoutExpired:
            raise VaultError('cloud_error', 'AWSの集計がタイムアウトしました。手動で再試行してください。', 502)
        finally:
            self.lock.release()
