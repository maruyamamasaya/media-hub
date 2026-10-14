#!/usr/bin/env python3
"""Check private S3 storage with isolated bytes; never access library originals."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


class AWS:
    def __init__(self, profile=None, region='ap-northeast-1'):
        self.options = ['--region', region, '--no-cli-pager', '--output', 'json']
        if profile:
            self.options += ['--profile', profile]

    def call(self, *args):
        result = subprocess.run(['aws', *self.options, *args], capture_output=True, text=True)
        if result.returncode:
            # CLI errors can include request details. Keep them out of application logs.
            raise RuntimeError(f'AWS operation failed: {args[0]} {args[1]} (exit {result.returncode})')
        return json.loads(result.stdout) if result.stdout.strip() else {}


def check(aws, bucket, write=False):
    aws.call('sts', 'get-caller-identity')
    aws.call('s3api', 'head-bucket', '--bucket', bucket)
    config = aws.call('s3api', 'get-public-access-block', '--bucket', bucket)['PublicAccessBlockConfiguration']
    if not all(config.get(name) is True for name in (
        'BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets'
    )):
        raise RuntimeError('Bucket Public Access Block must enable all four settings')
    if not write:
        return {'privateAccessBlock': True, 'roundTrip': 'not_run'}
    key = f'photo-hub-connection-check/{uuid.uuid4()}'
    payload = os.urandom(1024)
    digest = base64.b64encode(hashlib.sha256(payload).digest()).decode('ascii')
    uploaded = False
    version = None
    try:
        with tempfile.TemporaryDirectory(prefix='photo-hub-s3-') as directory:
            source = Path(directory) / 'source.bin'
            target = Path(directory) / 'download.bin'
            source.write_bytes(payload)
            result = aws.call('s3api', 'put-object', '--bucket', bucket, '--key', key,
                              '--body', str(source), '--if-none-match', '*',
                              '--checksum-algorithm', 'SHA256', '--checksum-sha256', digest,
                              '--server-side-encryption', 'AES256')
            uploaded = True
            version = result.get('VersionId')
            location = ['--bucket', bucket, '--key', key]
            if version:
                location += ['--version-id', version]
            head = aws.call('s3api', 'head-object', *location, '--checksum-mode', 'ENABLED')
            if head.get('ContentLength') != len(payload) or head.get('ChecksumSHA256') != digest:
                raise RuntimeError('S3 size or SHA-256 verification failed')
            aws.call('s3api', 'get-object', *location, '--checksum-mode', 'ENABLED', str(target))
            if target.read_bytes() != payload:
                raise RuntimeError('Downloaded bytes do not match uploaded bytes')
    finally:
        if uploaded:
            location = ['--bucket', bucket, '--key', key]
            if version:
                location += ['--version-id', version]
            try:
                aws.call('s3api', 'delete-object', *location)
            except RuntimeError as exc:
                raise RuntimeError(f'Test object cleanup failed; remove only {key}') from exc
    return {'privateAccessBlock': True, 'roundTrip': 'verified', 'testObjectRemoved': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile')
    parser.add_argument('--region', default='ap-northeast-1')
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--write-test', action='store_true', help='upload, verify, download and remove a 1 KiB test object')
    args = parser.parse_args()
    try:
        print(json.dumps(check(AWS(args.profile, args.region), args.bucket, args.write_test)))
    except (RuntimeError, OSError, KeyError, ValueError) as exc:
        parser.exit(1, f'{exc}\n')


if __name__ == '__main__':
    main()
