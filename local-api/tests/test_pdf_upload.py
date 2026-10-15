"""PDF routes use isolated inputs and fake S3; no personal files or AWS access."""
from pathlib import Path
import tempfile
import shutil
from unittest.mock import patch
import unittest

from test_folder_upload import FakeCloud, FolderUploads
from vault.encrypted_upload import EncryptedUploads
from vault.service import VaultError


def pdf_fixture():
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>']
    data = b'%PDF-1.4\n'; offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data)); data += str(i).encode() + b' 0 obj\n' + obj + b'\nendobj\n'
    xref = len(data)
    data += b'xref\n0 5\n0000000000 65535 f \n'
    for offset in offsets[1:]:
        data += f'{offset:010d} 00000 n \n'.encode()
    return data + f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()


class PDFUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / 'input'; self.source.mkdir()
        self.original = pdf_fixture(); (self.source / 'Book.PDF').write_bytes(self.original)
        self.cloud = FakeCloud()
        self.body = dict(path=str(self.source), bucket='test-bucket', profile='test', region='ap-northeast-1')

    def test_normal_pdf_upload_preview_and_verified_download(self):
        service = FolderUploads(self.root / 'normal', lambda *args: self.cloud)
        plan = service.scan(self.body)
        self.assertEqual(len(plan['items']), 1)
        service.upload(plan['id'])
        raw = service.read(plan['id']); self.assertEqual(raw['state'], 'complete', raw['error'])
        item = raw['items'][0]; self.assertEqual(item['mimeType'], 'application/pdf')
        self.assertEqual(self.cloud.objects[item['objectKey']], self.original)
        self.assertIn('thumbnailKey', item)
        path, mime, name = service.media(plan['id'], item['id'])
        self.assertEqual(path.read_bytes(), self.original); self.assertEqual(mime, 'application/pdf')
        service.release_media(path); self.assertFalse(path.exists())
        self.assertEqual((self.source / 'Book.PDF').read_bytes(), self.original)

    def test_encrypted_pdf_and_preview_never_upload_plaintext(self):
        service = EncryptedUploads(self.root / 'sealed', lambda *args: self.cloud)
        plan = service.scan(self.body)
        service.upload(plan['id'], '10000000-0000-4000-8000-000000000001', b'\x21' * 32)
        raw = service.uploads.read(plan['id']); self.assertEqual(raw['state'], 'complete', raw['error'])
        item = raw['items'][0]
        self.assertEqual(item['mimeType'], 'application/pdf'); self.assertIn('thumbnailID', item)
        self.assertEqual(len(self.cloud.objects), 3)
        for data in self.cloud.objects.values():
            self.assertTrue(data.startswith(b'MHSEAL01')); self.assertNotIn(self.original, data)
        self.assertEqual(list(service.uploads.root.glob('sealed-staging-*')), [])

    def test_164_and_250_mib_pdf_are_accepted_by_both_scanners(self):
        for size in (164 * 1024 ** 2, 250 * 1024 ** 2):
            with (self.source / 'Book.PDF').open('wb') as stream:
                stream.write(self.original)
                stream.truncate(size)
            for name, service in [('normal', FolderUploads(self.root / 'normal')),
                                  ('sealed', EncryptedUploads(self.root / 'sealed'))]:
                plan = service.scan(self.body)
                self.assertEqual(plan['items'][0]['byteSize'], size, name)

    def test_normal_164_mib_pdf_download_passes_viewer_limit_and_integrity(self):
        source = self.source / 'Book.PDF'
        with source.open('wb') as stream:
            stream.write(self.original)
            stream.truncate(164 * 1024 ** 2)
        service = FolderUploads(self.root / 'normal', lambda *args: self.cloud)
        plan = service.scan(self.body)
        raw = service.read(plan['id']); raw['state'] = 'complete'
        raw['items'][0]['state'] = 'verified'; service.save(raw)
        with patch.object(self.cloud, 'download', side_effect=lambda key, version, target: shutil.copyfile(source, target)):
            path, mime, name = service.media(plan['id'], raw['items'][0]['id'])
        self.assertEqual(path.stat().st_size, 164 * 1024 ** 2)
        self.assertEqual(mime, 'application/pdf')
        service.release_media(path)
        self.assertFalse(path.exists())

    def test_pdf_over_viewer_limit_rejected_in_both_scanners(self):
        with (self.source / 'Book.PDF').open('wb') as stream:
            stream.truncate(250 * 1024 ** 2 + 1)
        for service in [FolderUploads(self.root / 'normal'), EncryptedUploads(self.root / 'sealed')]:
            with self.assertRaises(VaultError) as error:
                service.scan(self.body)
            self.assertEqual(error.exception.code, 'too_large')
        self.assertEqual(self.cloud.objects, {})
