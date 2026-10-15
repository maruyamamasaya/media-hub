# Macフォルダ一覧の短期キャッシュ
## Request
フォルダ一覧表示までの待ち時間を減らし、簡易キャッシュと通信の集約を追加する。
## Investigation
一覧APIが保存完了履歴の管理情報を直列再取得し、履歴と一覧で鍵設定取得が重複していた。
## Changes
- S3管理情報の同期成功を30秒メモリ保持し、未取得・期限切れを最大3並列で取得。
- 一覧／履歴の鍵設定を10秒共有。同時取得はロックでまとめる。認可結果は保存せず要求ごとに判定。
- 素材認可・解除・変更は最新設定を取得し古いキャッシュを破棄。管理情報保存前に同期キャッシュを破棄。
- エラー時は古いキャッシュへ戻らない。再起動でキャッシュを破棄。
- 原本・画像キャッシュ、AWS構成、Swift画面は変更していない。
## Files Changed
- local-api/vault/app.py、cloud_trash.py、folder_privacy.py
- local-api/tests/test_cloud_trash.py、test_folder_privacy.py
- CURRENT.md、本記録
## Validation
- システムPythonはFastAPI未導入で失敗。既存.venvで実行。
- sandbox内では内部API起動テストが応答取得に失敗。許可された通常環境で全164テスト成功。
- 追加並列試験後のcloud_trash全15件成功。
- 共通契約生成check・git diff --check成功。文書verify実行。
## Result
短時間の一覧再取得で管理情報通信を省略し、初回は少数並列化。実行中のMacは再起動後にPython変更が反映される。
## Remaining Issues
Mac再起動・実S3の所要秒数・実画面は未検証。外部変更の一覧反映は管理情報で最大30秒、鍵設定で最大10秒遅れる。素材アクセスは最新認可を維持。
