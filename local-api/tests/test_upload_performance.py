"""Performance diagnostics must preserve failure/recovery and hide input details."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.upload_performance import UploadPerformance
from vault.folder_upload import FolderUploads, S3CLI
from test_folder_upload import FakeCloud


class UploadPerformanceTests(unittest.TestCase):
    def test_concurrent_aggregation_and_failure_propagation(self):
        metrics = UploadPerformance()
        def work(_):
            with metrics.measure('worker'):
                metrics.add('bytes', 2)
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(work, range(100)))
        with self.assertRaises(ValueError):
            with metrics.measure('failed'):
                raise ValueError('private-details')
        result = metrics.result()
        self.assertEqual(result['stages']['worker']['calls'], 100)
        self.assertEqual(result['counters']['bytes'], 200)
        self.assertEqual(result['stages']['failed']['failures'], 1)
        self.assertNotIn('private-details', json.dumps(result))

    def test_scan_failure_resume_and_report_write_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / 'private-name'; source.mkdir()
            (source / 'private-photo.png').write_bytes(b'original')
            cloud = FakeCloud()
            service = FolderUploads(root / 'library', lambda *args: cloud)
            plan = service.scan({'path': str(source), 'bucket': 'private-bucket',
                                 'profile': 'private-profile', 'region': 'ap-northeast-1'})
            directory = service.path(plan['id']).parent
            scan = json.loads((directory / 'scan-performance.json').read_text())
            self.assertEqual(scan['itemCount'], 1)
            self.assertEqual(scan['stages']['sha256']['calls'], 1)
            cloud.fail_catalog = True
            service.upload(plan['id'])
            failed = json.loads((directory / 'upload-performance.json').read_text())
            self.assertEqual(failed['state'], 'failed')
            self.assertEqual(failed['completedItems'], 1)
            self.assertEqual(service._performance, {})
            cloud.fail_catalog = False
            service.upload(plan['id'])
            resumed = json.loads((directory / 'upload-performance.json').read_text())
            self.assertEqual(resumed['state'], 'complete')
            self.assertEqual(resumed['completedItems'], 0)
            self.assertNotIn('private-', json.dumps([scan, failed, resumed]))
            with patch('vault.folder_upload.atomic_json', side_effect=OSError('disk')):
                service.save_performance(plan['id'], 'upload-performance.json', {})
            self.assertEqual(service.read(plan['id'])['state'], 'complete')

    def test_live_progress_reuses_worker_state_but_stop_still_reads_checkpoint(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / 'photos'; source.mkdir()
            (source / 'a.jpg').write_bytes(b'original')
            service = FolderUploads(root / 'library', lambda *args: FakeCloud())
            public = service.scan({'path': str(source), 'bucket': 'test-bucket',
                                   'profile': 'test', 'region': 'ap-northeast-1'})
            plan = service.read(public['id'])
            observed = []
            def work(item):
                with patch.object(service, 'read', side_effect=AssertionError('progress reread')):
                    service.report(plan['id'], item, 'uploading', 3)
                    observed.append(service.live[plan['id']]['bytes'])
            self.assertTrue(service.parallel_items(plan, work))
            self.assertEqual(observed, [3])
            # The memory view must not mask a pause persisted by another handler.
            saved = service.read(plan['id']); saved['stop'] = True; service.save(saved)
            self.assertTrue(service.stopped(plan['id']))
            service.clear_progress(plan['id'])
            self.assertNotIn(plan['id'], service._progress_plans)

    def test_s3_failures_and_payload_accounting_without_sensitive_arguments(self):
        client = S3CLI('secret-bucket', 'secret-profile', 'ap-northeast-1')
        client.performance = UploadPerformance()
        with tempfile.TemporaryDirectory() as temp:
            body = Path(temp) / 'secret-file'; body.write_bytes(b'1234')
            ok = subprocess.CompletedProcess([], 0, '{}', '')
            bad = subprocess.CompletedProcess([], 1, '', 'secret-error')
            with patch('vault.folder_upload.subprocess.run', side_effect=[ok, bad]):
                client.put(body, 'secret-key', 'secret-digest', 'image/png')
                with self.assertRaises(Exception):
                    client.head('secret-key')
        result = client.performance.result()
        self.assertEqual(result['stages']['s3.put-object']['calls'], 1)
        self.assertEqual(result['stages']['s3.head-object']['failures'], 1)
        self.assertEqual(result['counters']['acknowledgedBodyBytes'], 4)
        self.assertNotIn('secret', json.dumps(result))
