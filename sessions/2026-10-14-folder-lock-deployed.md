# フォルダ別パスワードの共有・非表示
## Request
本人がフォルダごとのパスワードをMacで設定し、解除前はフォルダ自体を隠し、iPhoneへ同じ設定を反映。AWS更新を明示承認。
## Investigation
既存S3カタログ・階層ID・本人JWT認可を確認。作業中に通常Mac起動がSwiftUIへ移行したことを確認し、現行Mac UIと同じAPI契約を照合。
## Changes
共通PBKDF2/HMAC認可・親子継承・名前／件数／派生／URLの除外・短期解除・revision無効化を追加。Macは条件付き共有設定保存、iPhoneは解除のみ。管理JSON1つを空で作成、閲覧Lambda・解除経路・読取IAMを更新。現行Macの鍵状態とエラー表示も接続。実パスワードは本人が入力する。
## Files Changed
backend/folder_security.py・reader.py・tests、infrastructure/reader.yaml、local-api/vault/folder_privacy.py・folder_upload.py・app.py・起動・tests、Webのフォルダ／再ロック画面、共通契約・生成DTO、ios/PhotoHub/CloudViewer.swift、macos/MediaHubMac/Runtime.swift・Views.swift、関連文書。
## Validation
ローカルAPI65・backend22・Swift15テスト成功。Web型チェック／ビルド、iOS Simulator／実機ビルド、既存署名検証、契約生成一致、文書full verify、git diff --check。模擬S3とブラウザで非表示→既存テストパスワード解除→表示→期限後再ロックを確認。実AWSで管理JSON読取・カタログ1件・未認証401を確認。
## Result
AWS更新完了。Vesperaへデータを保持した更新インストール・起動成功。現行SwiftUI Macもビルド・再起動済み。個人メディアの追加送信・削除なし。共有設定の鍵は0件で、本人のフォルダに勝手に設定していない。
## Remaining Issues
本人による実パスワード設定とiPhoneでの解除確認。初期版10フォルダ、5分解除。パスワード忘れの復旧UIは未実装。S3署名URL・取り出したコピーは即時失効できない。新しいMac構成への移行作業自体は別作業記録を参照。
