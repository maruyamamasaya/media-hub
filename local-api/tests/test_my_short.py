import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_vault import ROOT, image_bytes, validate_contract
from vault.service import Vault, VaultError
from vault.storage import checksum


class MyShortTests(unittest.TestCase):
    def setUp(self):
        root = ROOT / '.local/test-runs'
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temp.cleanup)
        self.vault = Vault(Path(self.temp.name) / 'data', Path(self.temp.name) / 'fixtures')

    def add(self, raw, name):
        job = self.vault.new_job()
        self.vault.add_stream(job, name, io.BytesIO(raw))
        item = self.vault.job(job)['items'][0]
        self.assertEqual(item['state'], 'ready', item)
        return self.vault.asset(item['assetId'])

    def test_random_pages_stable_unique_and_exclusions(self):
        assets = [self.add(image_bytes(color), color + '.png') for color in ['red', 'blue', 'green', 'orange', 'purple']]
        with self.vault.repo.connect() as db:
            db.execute("UPDATE assets SET trashedAt='2026-10-13' WHERE id=?", (assets[0]['id'],))
            db.execute("UPDATE assets SET storageLocation='development-remote',archivedAt='2026-10-13' WHERE id=?", (assets[1]['id'],))
        first = self.vault.list_assets(sort='random', seed='session', limit=1)
        self.assertEqual(first, self.vault.list_assets(sort='random', seed='session', limit=1))
        seen = [first['items'][0]['id']]
        cursor = first['nextCursor']
        while cursor:
            page = self.vault.list_assets(sort='random', seed='session', limit=1, cursor=cursor)
            seen += [a['id'] for a in page['items']]
            cursor = page['nextCursor']
        self.assertEqual(set(seen), {a['id'] for a in assets[2:]})
        self.assertEqual(len(seen), len(set(seen)))
        with self.assertRaises(VaultError):
            self.vault.list_assets(sort='random', seed='different', cursor=first['nextCursor'])
        tag = self.vault.create_entity('tags', 'short')
        collection = self.vault.create_entity('collections', 'short')
        self.vault.update(assets[2]['id'], {'revision': assets[2]['revision'], 'tagIds': [tag['id']], 'collectionIds': [collection['id']]})
        filtered = self.vault.list_assets(sort='random', seed='session', tag_ids=[tag['id']], collection=collection['id'])
        self.assertEqual([a['id'] for a in filtered['items']], [assets[2]['id']])

    def test_video_without_converter_preserves_original_and_retry(self):
        raw = b'opaque unsupported codec original'
        with patch('vault.service.shutil.which', return_value=None):
            asset = self.add(raw, 'private.mov')
            self.assertEqual(asset['kind'], 'video')
            self.assertEqual(len(self.vault.list_assets(kind='video')['items']), 1)
            original = next(f for f in asset['files'] if f['role'] == 'original')
            self.assertEqual(self.vault.storage.path(original['objectKey']).read_bytes(), raw)
            self.assertTrue(all(f['state'] == 'failed' for f in asset['files'] if f['role'] != 'original'))
            self.vault.preview(asset['id'])
            self.assertEqual(checksum(self.vault.storage.path(original['objectKey'])), original['sha256'])
            validate_contract(self.vault.asset(asset['id']), 'Asset')

    def test_conversion_success_and_failure_do_not_write_original(self):
        def convert(command, **kwargs):
            target = Path(command[-1])
            target.write_bytes(image_bytes() if target.suffix == '.jpg' else b'derived-video')
        with patch('vault.service.shutil.which', side_effect=lambda name: 'ffmpeg' if name == 'ffmpeg' else None), patch('vault.service.subprocess.run', side_effect=convert):
            asset = self.add(b'original-video', 'movie.mp4')
        original = next(f for f in asset['files'] if f['role'] == 'original')
        self.assertEqual(next(f for f in asset['files'] if f['role'] == 'display')['mimeType'], 'video/mp4')
        with patch('vault.service.shutil.which', return_value='ffmpeg'), patch('vault.service.subprocess.run', side_effect=subprocess.TimeoutExpired('ffmpeg', 180)):
            failed = self.vault.preview(asset['id'])
        self.assertEqual(next(f for f in failed['files'] if f['role'] == 'display')['state'], 'failed')
        self.assertEqual(self.vault.storage.path(original['objectKey']).read_bytes(), b'original-video')

if __name__ == '__main__':
    unittest.main()
