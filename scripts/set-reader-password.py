#!/usr/bin/env python3
"""Owner-run first password setup. Never writes passwords or prints CLI error bodies."""
import argparse
import getpass
import json
from pathlib import Path
import subprocess
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings', type=Path, default=Path(__file__).resolve().parents[1] / '.local/reader-deploy/settings.json')
    parser.add_argument('--profile', default='photo-hub')
    args = parser.parse_args()
    settings = json.loads(args.settings.read_text())
    password = getpass.getpass('iPhoneログイン用の新しいパスワード（8文字以上）: ')
    if password != getpass.getpass('確認のためもう一度: '):
        parser.exit(1, '入力が一致しません。設定していません。\n')
    if len(password) < 8 or not any(c.isupper() for c in password) or not any(c.islower() for c in password) or not any(c.isdigit() for c in password) or not any(not c.isalnum() for c in password):
        parser.exit(1, '8文字以上で、大文字・小文字・数字・記号を含めてください。\n')
    payload = json.dumps({'UserPoolId': settings['UserPoolId'], 'Username': settings['Username'], 'Password': password, 'Permanent': True})
    # Homebrew CLI reads file:///dev/stdin more than once. Pass JSON directly
    # to its in-process driver; the OS command line contains no password.
    aws_path = shutil.which('aws')
    if not aws_path:
        parser.exit(1, 'AWS CLIが見つかりません。\n')
    first_line = Path(aws_path).read_text().splitlines()[0]
    interpreter = first_line.removeprefix('#!').strip()
    if not first_line.startswith('#!') or not Path(interpreter).is_file():
        parser.exit(1, 'この設定ツールにはHomebrew版AWS CLIが必要です。\n')
    driver = 'import sys, awscli.clidriver; sys.exit(awscli.clidriver.create_clidriver().main(sys.argv[1:] + ["--cli-input-json", sys.stdin.read()]))'
    result = subprocess.run([interpreter, '-c', driver, '--profile', args.profile, '--region', 'ap-northeast-1', '--no-cli-pager', 'cognito-idp', 'admin-set-user-password'], input=payload, capture_output=True, text=True)
    if result.returncode:
        if 'InvalidPasswordException' in result.stderr:
            parser.exit(1, 'AWSのパスワード条件を満たしていません。8文字以上で大文字・小文字・数字・記号を含めてください。\n')
        if any(code in result.stderr for code in ('ExpiredToken', 'TokenRefresh', 'Unauthorized', 'Unable to locate credentials')):
            parser.exit(1, 'AWS認証の有効期限を確認してください。aws login --profile ' + args.profile + ' で再ログイン後に実行してください。\n')
        parser.exit(1, '設定できませんでした。AWSログインとパスワード条件を確認してください。\n')
    print('設定しました。iPhoneの「本人ログイン」で登録メールとこのパスワードを使ってください。')


if __name__ == '__main__':
    main()
