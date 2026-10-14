import io
import json
import os
import sys
from pathlib import Path
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reader
import usage_report

OWNER = '00000000-0000-4000-8000-000000000001'
REPORT = {'schemaVersion': 1, 'updatedAt': '2026-10-14T17:00:00+09:00', 'region': 'ap-northeast-1',
          'storageBytes': 100, 'currentBytes': 90, 'previousBytes': 10, 'normalBytes': 50,
          'encryptedBytes': 30, 'thumbnailBytes': 5, 'metadataBytes': 5, 'storageEstimateYen': 0.01,
          'targetYen': 2000, 'exchangeRate': 150, 'taxMultiplier': 1.1, 'rateUSDPerGiB': 0.025,
          'history': [{'date': '2026-10-14', 'storageBytes': 100, 'storageEstimateYen': 0.01}], 'notes': []}


class Missing(Exception):
    response = {'Error': {'Code': 'NoSuchKey'}}


class Fake:
    def __init__(self):
        self.raw = json.dumps(REPORT).encode()
        self.missing = False
        self.calls = []
    def get_object(self, **args):
        self.calls.append(args)
        if self.missing:
            raise Missing()
        return {'Body': io.BytesIO(self.raw)}


class UsageReaderTests(unittest.TestCase):
    def setUp(self):
        self.cloud = Fake()
        env = patch.dict(os.environ, {'BUCKET': 'test-bucket', 'OWNER_SUB': OWNER}); env.start(); self.addCleanup(env.stop)
        client = patch('reader.client', return_value=self.cloud); client.start(); self.addCleanup(client.stop)
    def call(self, owner=OWNER, method='GET'):
        return reader.handler({'rawPath': '/usage', 'requestContext': {'http': {'method': method}, 'authorizer': {'jwt': {'claims': {'sub': owner} if owner else {}}}}}, None)
    def test_owner_only_read_only_bounded_fixed_key(self):
        self.assertEqual(self.call(owner=None)['statusCode'], 401)
        self.assertEqual(self.call(owner='00000000-0000-4000-8000-000000000002')['statusCode'], 403)
        self.assertEqual(self.call(method='POST')['statusCode'], 405)
        self.assertEqual(self.cloud.calls, [])
        result = self.call()
        self.assertEqual(result['statusCode'], 200)
        self.assertEqual(json.loads(result['body']), REPORT)
        self.assertEqual(result['headers']['Cache-Control'], 'no-store')
        self.assertEqual(self.cloud.calls, [{'Bucket': 'test-bucket', 'Key': usage_report.KEY}])
    def test_missing_is_404_and_corrupt_or_oversized_not_returned(self):
        self.cloud.missing = True
        self.assertEqual(self.call()['statusCode'], 404)
        self.cloud.missing = False
        self.cloud.raw = b' ' * (usage_report.MAX_BYTES + 1)
        self.assertEqual(self.call()['statusCode'], 400)
        self.cloud.raw = json.dumps({**REPORT, 'objectKey': 'private'}).encode()
        self.assertEqual(self.call()['statusCode'], 400)
    def test_storage_failure_is_not_missing_or_zero(self):
        with patch.object(self.cloud, 'get_object', side_effect=RuntimeError()):
            self.assertEqual(self.call()['statusCode'], 502)
