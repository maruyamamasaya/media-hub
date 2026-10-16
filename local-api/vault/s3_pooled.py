"""Per-upload S3 client: one thread-safe SDK client and reusable TLS pool."""
from contextlib import ExitStack
from datetime import datetime
import json
from pathlib import Path
import shutil

import boto3
from botocore import xform_name
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError, TokenRetrievalError, UnauthorizedSSOTokenError, SSOTokenLoadError, CredentialRetrievalError

from .folder_upload import S3CLI, remote_matches
from .service import VaultError
from .upload_performance import timed_s3


def cli_value(value):
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: cli_value(v) for k, v in value.items() if k != 'ResponseMetadata'}
    if isinstance(value, list):
        return [cli_value(v) for v in value]
    return value


class S3Pooled(S3CLI):
    direct_put = True

    def __init__(self, bucket, profile, region, recorder=None, sdk=None):
        super().__init__(bucket, profile, region, recorder)
        try:
            self.sdk = sdk or boto3.Session(profile_name=profile, region_name=region).client(
                's3', config=Config(max_pool_connections=8, tcp_keepalive=True,
                                    connect_timeout=15, read_timeout=120,
                                    retries={'mode': 'standard', 'total_max_attempts': 3}))
        except BotoCoreError as exc:
            raise VaultError('aws_login_required', 'AWSへの再ログインが必要です。', 401) from exc

    @timed_s3
    def call(self, operation, *args, missing=False):
        """Keep the existing transfer/multipart interface and its page boundaries."""
        method_name = operation.replace('-', '_')
        api_name = self.sdk.meta.method_to_api_mapping[method_name]
        shape = self.sdk.meta.service_model.operation_model(api_name).input_shape
        members = {xform_name(k, '-'): (k, v) for k, v in shape.members.items()}
        params = {'Bucket': self.bucket}
        output = None
        self.record(requests=1)
        try:
            with ExitStack() as stack:
                index = 0
                while index < len(args):
                    option = args[index]
                    if option == '--no-paginate':
                        index += 1
                        continue
                    if not option.startswith('--'):
                        if operation != 'get-object' or output is not None:
                            raise ValueError('Unsupported positional S3 argument')
                        output = Path(option); index += 1
                        continue
                    name, member = members[option[2:]]
                    value = args[index + 1]; index += 2
                    if name == 'Body':
                        value = stack.enter_context(Path(value).open('rb'))
                    elif member.type_name in ('integer', 'long'):
                        value = int(value)
                    elif member.type_name in ('structure', 'list', 'map'):
                        value = json.loads(Path(value[7:]).read_text()) if value.startswith('file://') else json.loads(value)
                    params[name] = value
                result = getattr(self.sdk, method_name)(**params)
                body = result.pop('Body', None)
                if body is not None:
                    with body:
                        if output is None:
                            raise ValueError('Download destination required')
                        with output.open('wb') as stream:
                            shutil.copyfileobj(body, stream, length=1024 * 1024)
                    self.record(received_bytes=result.get('ContentLength', 0))
                return cli_value(result)
        except ClientError as exc:
            code = exc.response.get('Error', {}).get('Code', '')
            if missing and code in ('404', 'NoSuchKey', 'NotFound'):
                return None
            if code in ('ExpiredToken', 'InvalidToken', 'TokenRefreshRequired', 'InvalidAccessKeyId'):
                raise VaultError('aws_login_required', 'AWSへの再ログインが必要です。', 401) from exc
            if code in ('PreconditionFailed', 'ConditionalRequestConflict', '412'):
                raise VaultError('conflict', '保存情報が更新されました。最新の情報で再試行してください。', 409) from exc
            if code == 'NoSuchUpload':
                raise VaultError('multipart_expired', '途中送信の期限が切れています。', 409) from exc
            raise VaultError('cloud_error', 'S3通信に失敗しました。再試行してください。', 502) from exc
        except (NoCredentialsError, TokenRetrievalError, UnauthorizedSSOTokenError, SSOTokenLoadError, CredentialRetrievalError) as exc:
            raise VaultError('aws_login_required', 'AWSへの再ログインが必要です。', 401) from exc
        except BotoCoreError as exc:
            raise VaultError('cloud_error', 'S3通信に失敗しました。再試行してください。', 502) from exc

    def put_verified(self, path, key, digest, mime):
        """S3 validates SHA-256; use its versioned receipt, reconcile uncertain PUTs."""
        size = Path(path).stat().st_size
        try:
            response = self.put(path, key, digest, mime)
        except VaultError as exc:
            if exc.code not in ('conflict', 'cloud_error'):
                raise
            remote = self.head(key)
            if remote_matches(remote, size, digest):
                return remote
            if remote is not None:
                raise VaultError('integrity', '保存済みファイルのサイズ・SHA-256が一致しません。', 409) from exc
            raise
        if response.get('ChecksumSHA256') not in (None, digest):
            raise VaultError('integrity', 'S3応答のSHA-256が一致しません。', 409)
        if response.get('ChecksumSHA256') == digest and response.get('VersionId') and response.get('ETag'):
            return {**response, 'ContentLength': size}
        remote = self.head(key)
        if not remote_matches(remote, size, digest):
            raise VaultError('integrity', 'S3のサイズ・SHA-256照合に失敗しました。', 409)
        return remote

    def close(self):
        self.sdk.close()
