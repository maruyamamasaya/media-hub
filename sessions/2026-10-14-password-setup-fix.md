# 初回パスワード設定の修正
## Request
本人の初回パスワード設定が失敗する。
## Investigation
AWS CLI 2.37.13でfile:///dev/stdinによるJSON入力が拒否されることをダミー入力で再現。
## Changes
Homebrew AWS CLIのPythonドライバーへプロセス内でJSONを渡す。秘密値は標準入力のみで渡し、ファイル・OS引数・エラー本文へ出さない。条件エラーと認証エラーを安全な文言で分類。
## Files Changed
scripts/set-reader-password.py。
## Validation
ダミーJSONのCLIスケルトン検証成功。モックで秘密値がOS引数に含まれないことを確認。git diff --check成功。
## Result
スクリプトの不具合を修正。実パスワードの変更は実行していない。
## Remaining Issues
本人が修正済みスクリプトで再設定し、iPhoneへログインする。
