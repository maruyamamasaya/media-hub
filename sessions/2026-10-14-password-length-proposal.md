# 初回パスワード長の変更案
## Request
本人ログインの最低長を8文字にしたい。
## Investigation
Cognitoは8文字を許容する。現在のテンプレートと設定用スクリプトは12文字。
## Changes
両方を8文字へ変更する案を準備。大文字・小文字・数字・記号条件は維持。
## Files Changed
infrastructure/auth.yaml、scripts/set-reader-password.py。
## Validation
Python構文検証と差分の空白検証を実施。
## Result
ユーザーの明示承認後、media-hub-authを更新。AWS実設定でMinimumLength=8と大文字・小文字・数字・記号条件の維持を確認。
## Remaining Issues
初回パスワード設定は本人が実施。
