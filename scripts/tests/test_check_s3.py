import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('check_s3', Path(__file__).resolve().parents[1] / 'check-s3.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeAWS:
    def __init__(self, corrupt=False, private=True):
        self.calls = []
        self.corrupt, self.private = corrupt, private

    def call(self, *args):
        self.calls.append(args)
        operation = args[1]
        if operation == 'get-public-access-block':
            return {'PublicAccessBlockConfiguration': dict.fromkeys([
                'BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets'
            ], self.private)}
        if operation == 'put-object':
            self.payload = Path(args[args.index('--body') + 1]).read_bytes()
            self.digest = args[args.index('--checksum-sha256') + 1]
            return {'VersionId': 'test-version'}
        if operation == 'head-object':
            return {'ContentLength': len(self.payload), 'ChecksumSHA256': 'bad' if self.corrupt else self.digest}
        if operation == 'get-object':
            Path(args[-1]).write_bytes(self.payload)
        return {}


class S3CheckTests(unittest.TestCase):
    def test_read_only_does_not_write(self):
        aws = FakeAWS()
        self.assertEqual(module.check(aws, 'bucket')['roundTrip'], 'not_run')
        self.assertFalse(any(call[1] == 'put-object' for call in aws.calls))

    def test_private_check_precedes_write(self):
        aws = FakeAWS(private=False)
        with self.assertRaises(RuntimeError):
            module.check(aws, 'bucket', True)
        self.assertFalse(any(call[1] == 'put-object' for call in aws.calls))

    def test_round_trip_and_exact_version_cleanup(self):
        aws = FakeAWS()
        self.assertEqual(module.check(aws, 'bucket', True)['roundTrip'], 'verified')
        delete = aws.calls[-1]
        self.assertEqual(delete[1], 'delete-object')
        self.assertEqual(delete[delete.index('--version-id') + 1], 'test-version')

    def test_integrity_failure_still_cleans_test_object(self):
        aws = FakeAWS(corrupt=True)
        with self.assertRaisesRegex(RuntimeError, 'verification failed'):
            module.check(aws, 'bucket', True)
        self.assertEqual(aws.calls[-1][1], 'delete-object')
        self.assertFalse(any(call[1] == 'get-object' for call in aws.calls))

    def test_failed_put_never_deletes_existing_object(self):
        class FailedPut(FakeAWS):
            def call(self, *args):
                if args[1] == 'put-object':
                    raise RuntimeError('conditional write rejected')
                return super().call(*args)
        aws = FailedPut()
        with self.assertRaises(RuntimeError):
            module.check(aws, 'bucket', True)
        self.assertFalse(any(call[1] == 'delete-object' for call in aws.calls))

    def test_cleanup_failure_reports_test_key(self):
        class FailedDelete(FakeAWS):
            def call(self, *args):
                if args[1] == 'delete-object':
                    raise RuntimeError('denied')
                return super().call(*args)
        with self.assertRaisesRegex(RuntimeError, 'photo-hub-connection-check/'):
            module.check(FailedDelete(), 'bucket', True)


if __name__ == '__main__':
    unittest.main()
