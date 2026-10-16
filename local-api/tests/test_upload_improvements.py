"""Isolated upload timing/concurrency/resume tests; never calls AWS."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vault.folder_upload import FolderUploads, S3CLI, TransferPaused, hash_stream, remote_matches
from vault.service import VaultError
from vault.multipart_upload import MultipartUpload
from vault.app import create_app
from fastapi.testclient import TestClient
from test_folder_upload import FakeCloud, validate_contract


class MultipartCloud(S3CLI):
    def __init__(self):
        super().__init__('test-bucket', 'test-profile', 'ap-northeast-1')
        self.parts = {}; self.objects = {}; self.operations = []; self.sent = []
        self.fail_part = None; self.generation = 0; self.expired = False
        self.corrupt = False; self.lost_completion = False
    def call(self, operation, *args, **kwargs):
        self.operations.append((operation, args))
        def arg(key): return args[args.index(key) + 1]
        if operation == 'create-multipart-upload':
            self.generation += 1; self.parts = {}; return {'UploadId': str(self.generation)}
        if operation == 'list-parts':
            if self.expired:
                self.expired = False
                raise VaultError('multipart_expired', 'expired', 409)
            return {'Parts': [{'PartNumber': n, 'Size': len(data), 'ChecksumSHA256': sha(data), 'ETag': str(n)} for n, data in self.parts.items()]}
        if operation == 'upload-part':
            n = int(arg('--part-number'))
            if n == self.fail_part:
                raise VaultError('cloud_error', 'connection lost', 502)
            data = Path(arg('--body')).read_bytes()
            assert sha(data) == arg('--checksum-sha256')
            self.parts[n] = data; self.sent.append(n)
            return {'ChecksumSHA256': 'bad' if self.corrupt else sha(data), 'ETag': str(n)}
        if operation == 'complete-multipart-upload':
            assert arg('--if-none-match') == '*'
            listing = json.loads(Path(arg('--multipart-upload')[7:]).read_text())['Parts']
            for p in listing: assert p['ChecksumSHA256'] == sha(self.parts[p['PartNumber']])
            data = b''.join(self.parts[p['PartNumber']] for p in listing)
            self.objects[arg('--key')] = {'ContentLength': len(data), 'ChecksumSHA256': arg('--checksum-sha256')}
            if self.lost_completion:
                self.lost_completion = False
                raise VaultError('cloud_error', 'response lost', 502)
            return {}
        raise AssertionError(operation)
    def head(self, key): return self.objects.get(key)


def sha(data): return base64.b64encode(hashlib.sha256(data).digest()).decode()


class MultipartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / 'video'; self.source.write_bytes(b'abcdefghij')
        self.journal = self.root / 'resume.json'; self.cloud = MultipartCloud()
    def send(self, stopped=lambda: False):
        return self.cloud.put_resumable(self.source, 'media-hub/originals/test', sha(self.source.read_bytes()),
            'video/mp4', self.journal, 4, stopped, lambda n: None)
    def test_copy_hashes_in_one_pass_and_matches_full_and_composite(self):
        target = io.BytesIO(); values = []
        full, composite = hash_stream(io.BytesIO(b'abc'), target, values.append)
        self.assertEqual(target.getvalue(), b'abc'); self.assertEqual(full, hashlib.sha256(b'abc').hexdigest())
        self.assertEqual(values, [3]); self.assertTrue(remote_matches({'ContentLength': 3, 'ChecksumSHA256': composite}, 3, sha(b'abc'), composite))
        self.assertFalse(remote_matches({'ContentLength': 3, 'ChecksumSHA256': 'bad'}, 3, sha(b'abc'), composite))
    def test_resume_checks_remote_parts_and_skips_only_matching_data(self):
        self.cloud.fail_part = 2
        with self.assertRaises(VaultError): self.send()
        self.assertEqual(self.cloud.sent, [1])
        self.cloud.fail_part = None; result = self.send()
        self.assertEqual(self.cloud.sent, [1, 2, 3]); self.assertEqual(result['ContentLength'], 10)
        self.assertEqual(self.cloud.generation, 1); self.assertTrue(json.loads(self.journal.read_text())['complete'])
        self.send(); self.assertEqual(self.cloud.sent, [1, 2, 3])
    def test_replaces_corrupt_remote_part_and_rejects_changed_scope(self):
        self.cloud.fail_part = 2
        with self.assertRaises(VaultError): self.send()
        self.cloud.parts[1] = b'wrong'; self.cloud.fail_part = None
        self.send(); self.assertEqual(self.cloud.sent, [1, 1, 2, 3])
        self.source.write_bytes(b'changed')
        with self.assertRaises(VaultError): self.send()
    def test_pause_keeps_remote_parts_and_restart_remains_conditional(self):
        with self.assertRaises(TransferPaused): self.send(lambda: bool(self.cloud.sent))
        self.assertEqual(self.cloud.sent, [1]); self.send(); self.assertEqual(self.cloud.sent, [1, 2, 3])
        self.assertEqual(list(self.root.glob('part-*')), [])
    def test_expired_upload_restarts_and_corrupt_response_never_completes(self):
        self.cloud.fail_part = 2
        with self.assertRaises(VaultError): self.send()
        self.cloud.fail_part = None; self.cloud.expired = True
        self.send(); self.assertEqual(self.cloud.generation, 2)
        self.journal.unlink(); self.cloud.objects.clear(); self.cloud.corrupt = True
        with self.assertRaises(VaultError): self.send()
        self.assertEqual(self.cloud.objects, {})
    def test_completion_response_loss_keeps_expected_checksum_for_reconciliation(self):
        self.cloud.lost_completion = True
        with self.assertRaises(VaultError): self.send()
        journal = json.loads(self.journal.read_text())
        self.assertEqual(journal['composite'], self.cloud.head('media-hub/originals/test')['ChecksumSHA256'])


class UploadSchedulingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / 'Photos'; self.source.mkdir()
        for n in range(4): (self.source / f'{n}.png').write_bytes(f'image{n}'.encode())
        self.cloud = FakeCloud(); self.service = FolderUploads(self.root / 'data', lambda *args: self.cloud)
    def scan(self):
        return self.service.scan({'path': str(self.source), 'bucket':'test-bucket', 'profile':'test', 'region':'ap-northeast-1'})
    def wait(self):
        deadline = time.monotonic() + 5
        while self.service.running and time.monotonic() < deadline: time.sleep(.01)
        self.assertFalse(self.service.running)
    def test_scan_hashes_four_files_together_keeps_order_and_monotonic_progress(self):
        barrier = threading.Barrier(4)
        original = hash_stream
        active = peak = 0
        lock = threading.Lock()
        values = []
        def inspect(*args, **kwargs):
            nonlocal active, peak
            with lock:
                active += 1; peak = max(peak, active)
            try:
                barrier.wait(timeout=3)
                return original(*args, **kwargs)
            finally:
                with lock: active -= 1
        with patch('vault.folder_upload.hash_stream', side_effect=inspect):
            plan = self.service.scan({'path':str(self.source), 'bucket':'test-bucket', 'profile':'test', 'region':'ap-northeast-1'},
                                     progress=lambda amount, name, total: values.append(amount))
        self.assertEqual(peak, 4)
        self.assertEqual(values, sorted(values))
        self.assertEqual(values[-1], 24)
        raw = self.service.read(plan['id'])
        self.assertEqual([item['name'] for item in raw['items']], [f'{n}.png' for n in range(4)])
        for item in raw['items']:
            self.assertEqual(item['sha256'], hashlib.sha256((self.source / item['name']).read_bytes()).hexdigest())

    def test_large_files_remain_single_worker_to_bound_staging(self):
        plan = self.scan()
        active = peak = 0
        lock = threading.Lock()
        def work(item):
            nonlocal active, peak
            with lock:
                active += 1; peak = max(peak, active)
            time.sleep(.01)
            with lock: active -= 1
        with patch('vault.folder_upload.MULTIPART_THRESHOLD', 1):
            self.assertTrue(self.service.parallel_items(self.service.read(plan['id']), work))
        self.assertEqual(peak, 1)

    def test_changed_source_during_parallel_scan_does_not_save_a_plan(self):
        original = hash_stream
        def inspect(stream, **kwargs):
            result = original(stream, **kwargs)
            (self.source / '0.png').write_bytes(b'changed-source')
            return result
        with patch('vault.folder_upload.hash_stream', side_effect=inspect):
            with self.assertRaises(VaultError): self.scan()
        self.assertEqual(self.service.list(), [])
        self.assertEqual(self.cloud.puts, [])

    def test_jpeg_preview_downsampling_preserves_orientation_and_original(self):
        from PIL import Image
        from vault.encrypted_upload import EncryptedUploads
        source = self.source / 'rotated.jpg'
        exif = Image.Exif(); exif[274] = 6; exif[271] = 'private-camera'
        Image.new('RGB', (2400, 1600), 'red').save(source, exif=exif)
        original = source.read_bytes()
        plan = self.scan(); self.service.upload(plan['id'])
        raw = self.service.read(plan['id'])
        self.assertEqual(raw['state'], 'complete', raw['error'])
        item = next(i for i in raw['items'] if i['name'] == source.name)
        normal = self.cloud.objects[item['thumbnailKey']]
        target = self.root / 'sealed-preview.png'
        self.assertTrue(EncryptedUploads.thumbnail(source, target, 'image/jpeg'))
        for data in (normal, target.read_bytes()):
            self.assertLessEqual(len(data), 50_000)
            with Image.open(io.BytesIO(data)) as image:
                self.assertLess(image.width, image.height)
                self.assertLessEqual(max(image.size), 320)
                self.assertFalse(image.getexif())
        self.assertEqual(source.read_bytes(), original)
    def test_four_workers_overlap_but_never_exceed_limit_and_progress_is_valid(self):
        plan = self.scan(); barrier = threading.Barrier(4); lock = threading.Lock(); active = 0; peak = 0
        original = self.cloud.put
        def put(path, key, digest, mime, etag=None):
            nonlocal active, peak
            if '/originals/' in key:
                with lock: active += 1; peak = max(peak, active)
                barrier.wait(timeout=3)
                time.sleep(.01)
                validate_contract(self.service.public(self.service.read(plan['id'])), 'FolderUpload')
                with lock: active -= 1
            return original(path, key, digest, mime, etag)
        with patch.object(self.cloud, 'put', side_effect=put): self.service.upload(plan['id'])
        raw = self.service.read(plan['id']); self.assertEqual(raw['state'], 'complete', raw['error']); self.assertEqual(peak, 4)
        self.assertEqual(self.service.public(raw)['completed'], 4)
    def test_queue_requires_confirmation_runs_in_order_and_failure_stops_remaining(self):
        one, two = self.scan(), self.scan()
        with self.assertRaises(VaultError): self.service.start_queue([one['id'], two['id']], {})
        self.cloud.fail_catalog = True
        self.service.start_queue([one['id'], two['id']], {'confirmUpload':True}); self.wait()
        self.assertEqual(self.service.read(one['id'])['state'], 'failed')
        self.assertEqual(self.service.read(two['id'])['state'], 'paused')
        self.cloud.fail_catalog = False
        self.service.start_queue([one['id'], two['id']], {'confirmUpload':True}); self.wait()
        self.assertTrue(all(self.service.read(p['id'])['state'] == 'complete' for p in (one, two)))
    def test_stop_cancels_reserved_folders_and_restart_never_connects(self):
        one, two = self.scan(), self.scan()
        self.cloud.after_put = lambda: self.service.pause(one['id'])
        self.service.start_queue([one['id'], two['id']], {'confirmUpload':True}); self.wait()
        self.assertTrue(all(self.service.read(p['id'])['state'] == 'paused' for p in (one, two)))
        raw = self.service.read(two['id']); raw['state'] = 'queued'; self.service.save(raw)
        restored = FolderUploads(self.root / 'data', lambda *args: self.fail('cloud access on restart'))
        self.assertEqual(restored.read(two['id'])['state'], 'interrupted')
    def test_async_scan_is_local_reports_bytes_and_api_boundaries(self):
        app = create_app(self.root / 'api', cloud_only=True); client = TestClient(app); headers = {'host':'127.0.0.1:8765'}
        body = {'path':str(self.source),'bucket':'test-bucket','profile':'test','region':'ap-northeast-1'}
        endpoint = '/api/v1/folder-uploads/scan-jobs'
        self.assertEqual(client.post(endpoint, json=body, headers={'host':'evil.invalid'}).status_code, 403)
        job = client.post(endpoint, json=body, headers=headers).json()
        for _ in range(100):
            status = client.get(endpoint + '/' + job['id'], headers=headers).json()
            if status['state'] != 'scanning': break
            time.sleep(.01)
        self.assertEqual(status['state'], 'complete'); self.assertEqual(status['bytes'], 24)
        self.assertEqual(client.post('/api/v1/folder-uploads/queue', json={'planIds':[status['planId']], 'confirmUpload':False}, headers=headers).status_code,400)


class EndToEndMultipartCloud(FakeCloud, MultipartUpload):
    def __init__(self):
        super().__init__(); self.bucket = 'test-bucket'; self.sessions = {}; self.sent_parts = []
        self.fail_second = True; self.composites = {}
    def head(self, key):
        value = super().head(key)
        if value and key in self.composites: value['ChecksumSHA256'] = self.composites[key]
        return value
    def call(self, operation, *args):
        if operation == 'list-objects-v2':
            return FakeCloud.call(self, operation, *args)
        def arg(key): return args[args.index(key) + 1]
        key = arg('--key')
        if operation == 'create-multipart-upload':
            upload_id = str(len(self.sessions) + 1)
            self.sessions[upload_id] = {'key': key, 'parts': {}}
            return {'UploadId': upload_id}
        session = self.sessions[arg('--upload-id')]; assert session['key'] == key
        if operation == 'list-parts':
            return {'Parts':[{'PartNumber': n, 'Size':len(data), 'ChecksumSHA256':sha(data), 'ETag':str(n)} for n, data in session['parts'].items()]}
        if operation == 'upload-part':
            number = int(arg('--part-number'))
            if number == 2 and self.fail_second:
                raise VaultError('cloud_error', 'test interrupted', 502)
            data = Path(arg('--body')).read_bytes(); assert sha(data) == arg('--checksum-sha256')
            session['parts'][number] = data; self.sent_parts.append((key, number))
            return {'ChecksumSHA256': sha(data), 'ETag':str(number)}
        if operation == 'complete-multipart-upload':
            assert arg('--if-none-match') == '*'; assert key not in self.objects
            listing = json.loads(Path(arg('--multipart-upload')[7:]).read_text())['Parts']
            data = b''.join(session['parts'][p['PartNumber']] for p in listing)
            expected = sha(b''.join(hashlib.sha256(session['parts'][p['PartNumber']]).digest() for p in listing)) + '-' + str(len(listing))
            assert expected == arg('--checksum-sha256')
            self.objects[key] = data; self.composites[key] = expected; self.puts.append(key)
            return {}
        raise AssertionError(operation)


class MultipartIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / 'Photos'; self.source.mkdir()
        from PIL import Image
        Image.new('RGB', (32, 32), 'red').save(self.source / 'photo.png')
        with (self.source / 'photo.png').open('ab') as stream: stream.write(b'\0' * 4096)
        self.cloud = EndToEndMultipartCloud()
        self.body = {'path':str(self.source),'bucket':'test-bucket','profile':'test','region':'ap-northeast-1'}
        self.addCleanup(patch.stopall)
        patch('vault.folder_upload.PART_SIZE', 64).start()
        patch('vault.folder_upload.MULTIPART_THRESHOLD', 100).start()
        patch('vault.encrypted_upload.MULTIPART_THRESHOLD', 100).start()
    def test_normal_resume_and_repeat_scan_match_composite_without_resending(self):
        service = FolderUploads(self.root / 'normal', lambda *args: self.cloud)
        plan = service.scan(self.body); service.upload(plan['id'])
        self.assertEqual(service.read(plan['id'])['state'], 'failed')
        self.cloud.fail_second = False
        service = FolderUploads(self.root / 'normal', lambda *args: self.cloud)
        service.upload(plan['id']); self.assertEqual(service.read(plan['id'])['state'], 'complete')
        originals = [n for k, n in self.cloud.sent_parts if '/originals/' in k]
        self.assertEqual(originals.count(1), 1)
        second = service.scan(self.body); before = list(self.cloud.sent_parts)
        service.upload(second['id']); self.assertEqual(service.read(second['id'])['state'], 'complete')
        self.assertEqual(before, self.cloud.sent_parts)
    def test_old_plan_recovers_composite_from_journal_after_completion_response_loss(self):
        service = FolderUploads(self.root / 'old-plan', lambda *args: self.cloud)
        plan = service.scan(self.body); raw = service.read(plan['id'])
        for item in raw['items']: item.pop('multipartSHA256')
        service.save(raw); self.cloud.fail_second = False
        service.upload(plan['id']); self.assertEqual(service.read(plan['id'])['state'], 'complete')
        raw = service.read(plan['id'])
        for item in raw['items']: item.pop('multipartSHA256')
        raw['state'] = 'interrupted'; service.save(raw)
        before = list(self.cloud.sent_parts)
        restored = FolderUploads(self.root / 'old-plan', lambda *args: self.cloud)
        restored.upload(plan['id']); self.assertEqual(restored.read(plan['id'])['state'], 'complete')
        self.assertEqual(before, self.cloud.sent_parts)

    def test_encrypted_restart_reuses_identical_ciphertext_and_cleans_after_success(self):
        from vault.encrypted_upload import EncryptedUploads
        from test_encrypted_upload import KEY_ID, KEY
        service = EncryptedUploads(self.root / 'secret', lambda *args: self.cloud)
        if not service.helper.is_file(): self.fail('Build MediaHubCrypto before running this test')
        plan = service.scan(self.body); raw = service.uploads.read(plan['id']); raw['keyID'] = KEY_ID; service.uploads.save(raw)
        service.upload(plan['id'], KEY_ID, KEY)
        self.assertEqual(service.uploads.read(plan['id'])['state'], 'failed')
        ciphertext = next((service.uploads.path(plan['id']).parent / 'ciphertext').glob('*.sealed'))
        before = ciphertext.read_bytes()
        self.assertTrue(before.startswith(b'MHSEAL01'))
        self.assertNotIn(base64.b64encode(KEY).decode(), service.uploads.path(plan['id']).read_text())
        self.cloud.fail_second = False
        restored = EncryptedUploads(self.root / 'secret', lambda *args: self.cloud)
        restored.upload(plan['id'], KEY_ID, KEY)
        raw = restored.uploads.read(plan['id']); self.assertEqual(raw['state'], 'complete', raw['error'])
        key = f'media-hub/encrypted-objects/{KEY_ID}/{plan["id"]}/{raw["items"][0]["objectID"]}.bin'
        self.assertEqual(self.cloud.objects[key], before)
        self.assertEqual([n for k,n in self.cloud.sent_parts if k == key].count(1), 1)
        self.assertFalse(ciphertext.exists())
        self.assertEqual(list(restored.uploads.root.glob('sealed-staging-*')), [])
        self.assertTrue((self.source / 'photo.png').is_file())


class UploadPrivacyTests(unittest.TestCase):
    def test_async_rescan_and_queue_cannot_bypass_locked_root(self):
        from test_folder_privacy import PrivateCloud, security
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / 'Photos'; source.mkdir(); (source / 'photo.png').write_bytes(b'image')
            cloud = PrivateCloud(); app = create_app(root / 'data', privacy_enabled=True)
            service = app.state.folder_uploads; service.client_factory = lambda *args: cloud
            body = {'path':str(source),'bucket':'test-private-bucket','profile':'test','region':'ap-northeast-1'}
            plan = service.scan(body); raw = service.read(plan['id'])
            cloud.settings['locks'] = [security.make_lock(raw['rootId'], raw['folders'][0]['id'], '012345')]; cloud.install_settings()
            with TestClient(app, base_url='http://127.0.0.1') as client:
                self.assertEqual(client.post('/api/v1/folder-uploads/scan-jobs', json=body).status_code,403)
                self.assertEqual(client.post('/api/v1/folder-uploads/queue', json={'planIds':[plan['id']], 'confirmUpload':True}).status_code,403)
            self.assertEqual(cloud.puts, []); self.assertEqual(service.read(plan['id'])['state'], 'planned')
    def test_filtered_plan_does_not_expose_hidden_progress(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / 'Photos'; source.mkdir()
            (source / 'visible.png').write_bytes(b'image'); (source / 'hidden.png').write_bytes(b'private')
            service = FolderUploads(root / 'data')
            result = service.scan({'path':str(source),'bucket':'test-bucket','profile':'test','region':'ap-northeast-1'})
            raw = service.read(result['id'])
            service.live[raw['id']] = {'phase':'uploading','name':'hidden.png','bytes':6,'totalBytes':12,'remainingSeconds':5,'activeFiles':1}
            raw['items'] = [i for i in raw['items'] if i['name'] == 'visible.png']; raw['byteSize'] = 5
            self.assertNotIn('progress', service.public(raw))
