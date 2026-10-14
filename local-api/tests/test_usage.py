import json
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.usage import Usage
from vault.folder_upload import S3CLI
from vault.app import create_app
from vault.service import VaultError
from test_folder_upload import FakeCloud
from test_vault import validate_contract
import usage_report

DEST = {'bucket': 'test-bucket', 'profile': 'test-profile', 'region': 'ap-northeast-1'}


class Cloud(FakeCloud):
    def __init__(self):
        super().__init__()
        self.calls = []
        self.storage_class = 'STANDARD'
    def call(self, operation, *args):
        self.calls.append((operation, args))
        assert operation == 'list-object-versions'
        assert args[:2] == ('--prefix', 'media-hub/')
        if '--key-marker' not in args:
            return {'IsTruncated': True, 'NextKeyMarker': 'next', 'NextVersionIdMarker': 'v1', 'Versions': [
                {'Key': 'media-hub/originals/sample', 'Size': 2**30, 'IsLatest': True, 'StorageClass': self.storage_class},
                {'Key': 'media-hub/originals/sample', 'Size': 100, 'IsLatest': False}]}
        return {'Versions': [
            {'Key': 'media-hub/encrypted-objects/sample', 'Size': 200, 'IsLatest': True},
            {'Key': 'media-hub/thumbnails/sample', 'Size': 30, 'IsLatest': True},
            {'Key': 'media-hub/catalogs/sample', 'Size': 10, 'IsLatest': True}],
                'DeleteMarkers': [{'Key': 'media-hub/gone'}]}


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cloud = Cloud()
        self.service = Usage(self.root, client_factory=lambda *args: self.cloud)
        self.budget_patch = patch.object(self.service, 'budget', return_value={'limitUSD': 10, 'actualUSD': 1.1, 'forecastUSD': None, 'notificationCount': 3, 'recipientCount': 1})
        self.budget_patch.start(); self.addCleanup(self.budget_patch.stop)

    def test_aggregate_pages_old_versions_and_contract_without_names(self):
        value = self.service.refresh(DEST)
        validate_contract(value, 'UsageReport')
        self.assertEqual(value['storageBytes'], 2**30 + 340)
        self.assertEqual(value['previousBytes'], 100)
        self.assertEqual(value['storageEstimateYen'], 4.13)
        self.assertEqual(len(self.cloud.calls), 2)
        self.assertEqual(self.cloud.puts, [usage_report.KEY])
        raw = json.dumps(value)
        for private in ('sample', 'test-bucket', 'test-profile', 'objectKey', 'Address'):
            self.assertNotIn(private, raw)

    def test_same_day_replaces_history_and_reads_shared_history_on_new_mac(self):
        self.service.refresh(DEST)
        other_root = self.root / 'other'; other_root.mkdir()
        other = Usage(other_root, client_factory=lambda *args: self.cloud)
        with patch.object(other, 'budget', side_effect=ValueError()):
            value = other.refresh(DEST)
        self.assertEqual(len(value['history']), 1)
        self.assertNotIn('budget', value)
        self.assertEqual(other.cached(DEST), value)

    def test_missing_is_not_zero_and_destination_isolation(self):
        with self.assertRaises(VaultError) as exc:
            self.service.cached(DEST)
        self.assertEqual(exc.exception.status, 404)
        self.assertEqual(self.cloud.calls, [])
        self.service.refresh(DEST)
        with self.assertRaises(VaultError):
            self.service.cached({**DEST, 'bucket': 'different-bucket'})

    def test_non_standard_or_non_tokyo_is_not_priced_as_standard_tokyo(self):
        self.cloud.storage_class = 'GLACIER'
        self.assertIsNone(self.service.refresh(DEST)['storageEstimateYen'])
        self.cloud.storage_class = 'STANDARD'
        self.assertIsNone(self.service.refresh({**DEST, 'region': 'us-east-1'})['storageEstimateYen'])

    def test_failed_save_keeps_last_local_report_and_corruption_refused(self):
        previous = self.service.refresh(DEST)
        with patch.object(self.cloud, 'put', side_effect=VaultError('cloud_error', 'test', 502)):
            with self.assertRaises(VaultError):
                self.service.refresh(DEST)
        self.assertEqual(self.service.cached(DEST), previous)
        self.cloud.objects[usage_report.KEY] = b'{"objectKey":"private"}'
        with self.assertRaises(ValueError):
            self.service.refresh(DEST)

    def test_activity_is_daily_persistent_and_scoped(self):
        self.service.record(DEST, requests=2, received_bytes=300)
        self.service.record(DEST, requests=1)
        other = Usage(self.root)
        value = other.activity(DEST)
        self.assertEqual((value[0]['requests'], value[0]['receivedBytes']), (3, 300))
        self.assertEqual(other.activity({**DEST, 'profile': 'other'}), [])

    def test_cli_counts_errors_and_only_download_bytes(self):
        calls = []
        client = S3CLI(**DEST, recorder=lambda **value: calls.append(value))
        with patch('vault.folder_upload.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '{"ContentLength":123}', '')):
            client.call('get-object', '/tmp/unused')
            client.call('head-object')
        self.assertEqual(sum(c.get('requests', 0) for c in calls), 2)
        self.assertEqual(sum(c.get('received_bytes', 0) for c in calls), 123)
        with patch('vault.folder_upload.subprocess.run', return_value=subprocess.CompletedProcess([], 1, '', 'ExpiredToken')):
            with self.assertRaises(VaultError):
                client.call('get-object')
        self.assertEqual(sum(c.get('requests', 0) for c in calls), 3)

    def test_authenticated_desktop_boundary_and_no_cloud_on_cached_read(self):
        app = create_app(self.root / 'api', desktop_token='token', desktop_origin='http://127.0.0.1:8765', cloud_only=True)
        app.state.usage.client_factory = lambda *args: self.cloud
        client = TestClient(app, base_url='http://127.0.0.1:8765')
        self.assertEqual(client.post('/api/v1/usage/refresh', json=DEST).status_code, 401)
        headers = {'x-photo-hub-token': 'token'}
        self.assertEqual(client.post('/api/v1/usage', json=DEST, headers=headers).status_code, 404)
        self.assertEqual(client.post('/api/v1/usage/activity', json=DEST, headers=headers).json(), [])
        self.assertEqual(self.cloud.calls, [])

    def test_metadata_and_inconsistent_history_rejected(self):
        value = self.service.refresh(DEST)
        for invalid in ({**value, 'url': 'secret'}, {**value, 'storageBytes': 0}, {**value, 'history': value['history'] * 2}, {**value, 'exchangeRate': float('nan')}):
            with self.assertRaises(ValueError):
                usage_report.validate(invalid)
