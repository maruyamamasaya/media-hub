# iPhone本人ログインを継続
## Request
毎回パスワードを求める負担を改善。
## Investigation
refresh tokenは既にKeychain保存されるが、CloudViewer起動時にsignedInを復帰していなかった。
## Changes
起動時と本人ログイン操作時に保存済みtokenで復帰。保存なし・期限切れだけ対話ログイン。一時失敗ではtokenを保持。既存Keychain識別・権限を維持し更新保存を原子的に実施。フォルダPINは復帰しない。
## Files Changed
Cloud.swift、CloudViewer.swift、IntegrationTests.swift、CURRENT、TESTING、docs/S3-READER.md、この記録。
## Validation
初回テストは署名なしSimulatorのKeychain権限で失敗。模擬保存領域へ隔離した復帰・一時失敗・期限切れ・ログアウトテスト成功。iphoneosビルド、既存署名deep strict、Vesperaへの上書きinstall・launch成功。
## Result
実機更新済み。AWS設定・token保持期間・メディアは変更なし。パスワード保存なし。
## Remaining Issues
本人の実Keychainからの復帰画面確認。期限切れ・ログアウト後は再ログインが必要。
