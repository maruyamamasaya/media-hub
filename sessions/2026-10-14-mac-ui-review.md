# Mac UI見直しの初期確認
## Request
Macアプリ全体のUIデザインを見直したい。
## Investigation
MacRootView、閲覧・アップロード・軽量版・設定、Galleryの配置を確認。現在のアプリ画面も確認したが、非アクティブ時の保護表示だったため実メディア一覧の見た目は未確認。
## Changes
本人が写真アプリ寄り・アップロード画面を指定。選択エリア、確認カード、簡潔な履歴へ整理。続く要望に対応し、未送信の確認待ちだけを一覧から取り消すAPI・ごみ箱ボタンを追加。原本・S3データは変更せず、予定記録はローカルdiscarded領域へ退避する。
## Files Changed
macos/MediaHubMac/Views.swift、local-api/vault/app.py・folder_upload.py、関連Pythonテスト、CURRENT.md、docs/MAC-SWIFTUI.md、この記録。
## Validation
verify-desktop成功（Python74件、backend24件、Swift16件、契約・文書・.appビルド・差分）。取り消しの原本保持、クラウド不変更、再起動後非表示、送信中・送信済み拒否、API境界を検証。更新版実画面で選択エリア・履歴のごみ箱・完了カードを確認。画面確認中に確認待ちがなくなり完了9件の履歴が残ったことを確認。
## Result
更新版アプリでアップロード画面の見直しと確認待ちの取り消しを利用可能。
## Remaining Issues
閲覧・その他画面全体の見直しは未実施。続くサムネイル保存方針の相談は検討段階。実装確認で新たなS3送信は行っていない。
