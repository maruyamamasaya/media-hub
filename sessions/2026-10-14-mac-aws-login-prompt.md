# Mac AWS再ログイン案内
## Request
再ログインが必要な場合にポップアップで誘導する。
## Investigation
AWS CLIエラーが汎用cloud_errorとなり、Mac初回一覧失敗で2秒ごとの確認が継続していた。APIのcodeはMacで捨てていた。
## Changes
期限切れ・認証情報なしを専用codeで通知。Macは一度だけ案内し、自動確認を停止。保存先に対応するAWSログインをターミナルで開き、本人の接続確認で再読込。画面と設定にも導線。コマンド引数はシェル引用し、資格情報は保存しない。送信は自動再開しない。
## Files Changed
local-api/vault/folder_upload.py、関連Pythonテスト、macos/MediaHubMacのModel・Runtime・Views、RuntimeTests、CURRENT.md、docs/MAC-SWIFTUI.md、この記録。
## Validation
verify-desktop成功: Pythonローカル71件、backend24件、Swift16件、契約生成・文書・.appビルド・差分検証。制限内の初回実行はloopback子プロセステストで失敗し、承認環境で全件成功。認証と権限・通信エラーの区別、案内の重複抑止を模擬テストで確認。
## Result
更新版.appを生成し、通常終了後に開き直す操作が成功。AWSリソース・保存データは変更なし。
## Remaining Issues
本人の実セッションを失効させてのポップアップ・ブラウザログイン一連の操作は未実施。
