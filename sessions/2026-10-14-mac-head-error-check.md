# Mac HEADエラーと費用確認
## Request
Macアプリで繰り返すhead-objectエラーと費用影響を急ぎ確認。
## Investigation
MacModelの初回refresh失敗でneedsRefreshがtrueのまま残り、約2秒ごとに一覧取得を再試行する。FolderPrivacy.libraryは鍵設定のHEADを実行する。実AWS読取確認でphoto-hubのログインセッション期限切れを確認。
## Changes
調査記録のみ。AWS設定・保存データ・実装は変更なし。
## Files Changed
この記録。
## Validation
実STSと鍵設定HEADの読取確認。ローカル履歴は9件すべてverifiedのcompleteが1件、未送信plannedが1件。AWS公式エラー課金資料を確認。テストはコード変更なしのため未実行。
## Result
ログイン期限切れでAWS操作前に失敗するため、この認証エラーの繰り返しによるS3リクエスト課金は発生しない。一覧再試行は続くがアップロードの自動再開はない。
## Remaining Issues
本人のAWS再ログインが必要。初回一覧取得失敗時の自動再試行制御は未修正。確定請求額は未取得。

## Follow-up
本人の依頼で `.local/Media Hub.app` をopenで起動し、Finderで場所を表示。通常の制限内起動はLaunchServicesエラーになったが、承認された起動操作は成功。再ログインは未実施。

本人の再ログイン完了報告後、実STS認証と実際の鍵設定へのchecksum有効HEADがともに成功。認証期限切れとHEAD接続失敗は解消。Mac画面の表示復旧は本人確認待ち。自動再試行制御と確定請求の未確認は継続。
