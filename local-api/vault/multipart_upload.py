"""Conditional multipart uploads with server-checked SHA-256 and local resume journals."""
import base64
import hashlib
import json
from pathlib import Path
import tempfile

from .service import VaultError


class MultipartUpload:
    def put_resumable(self, source, key, digest, mime, journal, part_size, stopped, progress):
        from .folder_upload import atomic_json, TransferPaused
        source, journal = Path(source), Path(journal)
        scope = {'bucket': self.bucket, 'key': key, 'digest': digest,
                 'size': source.stat().st_size, 'partSize': part_size}
        state = json.loads(journal.read_text()) if journal.exists() else None
        if state and state.get('scope') != scope:
            raise VaultError('integrity', '途中送信の記録とデータが一致しません。', 409)
        if state and state.get('complete'):
            remote = self.head(key)
            if remote and remote.get('ChecksumSHA256') == state['composite'] and remote.get('ContentLength') == scope['size']:
                progress(scope['size'])
                return remote
            raise VaultError('integrity', '保存済みの分割送信を確認できません。', 409)
        for attempt in range(2):
            if stopped():
                raise TransferPaused()
            if state is None:
                created = self.call('create-multipart-upload', '--key', key, '--content-type', mime,
                    '--server-side-encryption', 'AES256', '--storage-class', 'STANDARD',
                    '--checksum-algorithm', 'SHA256', '--checksum-type', 'COMPOSITE')
                state = {'scope': scope, 'uploadId': created['UploadId'], 'complete': False}
                atomic_json(journal, state)
            try:
                uploaded, marker = {}, None
                while True:
                    args = ['--key', key, '--upload-id', state['uploadId']]
                    if marker is not None:
                        args += ['--part-number-marker', str(marker)]
                    page = self.call('list-parts', *args)
                    uploaded.update({p['PartNumber']: p for p in page.get('Parts', [])})
                    if not page.get('IsTruncated'):
                        break
                    marker = page['NextPartNumberMarker']
                full, hashes, parts, amount = hashlib.sha256(), [], [], 0
                with source.open('rb') as stream, tempfile.TemporaryDirectory(dir=journal.parent, prefix='part-') as temp:
                    number = 0
                    while chunk := stream.read(part_size):
                        if stopped():
                            raise TransferPaused()
                        number += 1
                        full.update(chunk)
                        part_digest = hashlib.sha256(chunk).digest()
                        checksum = base64.b64encode(part_digest).decode()
                        hashes.append(part_digest)
                        remote = uploaded.get(number)
                        if not remote or remote.get('Size') != len(chunk) or remote.get('ChecksumSHA256') != checksum:
                            path = Path(temp) / 'data'
                            path.write_bytes(chunk)
                            remote = self.call('upload-part', '--key', key, '--upload-id', state['uploadId'],
                                '--part-number', str(number), '--body', str(path),
                                '--checksum-algorithm', 'SHA256', '--checksum-sha256', checksum)
                            if remote.get('ChecksumSHA256') != checksum:
                                raise VaultError('integrity', '分割データのSHA-256照合に失敗しました。', 409)
                        parts.append({'PartNumber': number, 'ETag': remote['ETag'], 'ChecksumSHA256': checksum})
                        amount += len(chunk)
                        progress(amount)
                        # list-parts is the authority on resume; journal has no unchecked part cache.
                    if amount != scope['size'] or base64.b64encode(full.digest()).decode() != digest:
                        raise VaultError('integrity', '分割送信の元データが変更されています。', 409)
                    if stopped():
                        raise TransferPaused()
                    composite = base64.b64encode(hashlib.sha256(b''.join(hashes)).digest()).decode() + '-' + str(len(parts))
                    state['composite'] = composite
                    atomic_json(journal, state)
                    manifest = Path(temp) / 'parts.json'
                    manifest.write_text(json.dumps({'Parts': parts}))
                    self.call('complete-multipart-upload', '--key', key, '--upload-id', state['uploadId'],
                        '--multipart-upload', 'file://' + str(manifest), '--checksum-sha256', composite,
                        '--checksum-type', 'COMPOSITE', '--if-none-match', '*')
                remote = self.head(key)
                if not remote or remote.get('ContentLength') != amount or remote.get('ChecksumSHA256') != composite:
                    raise VaultError('integrity', '分割送信の完了を照合できません。', 409)
                state['complete'] = True
                atomic_json(journal, state)
                return remote
            except VaultError as exc:
                if exc.code != 'multipart_expired' or attempt:
                    raise
                # Bucket lifecycle may have removed an old unfinished upload.
                state = None
        raise VaultError('cloud_error', '分割送信を再開できません。', 502)
