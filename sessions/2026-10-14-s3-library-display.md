# S3アップロード済み素材の表示接続
## Request
S3へアップロードしたが「一致する素材がありません」となり表示できない。
## Investigation
Macの転送履歴2件中、保存完了1件（9原本全件照合）と未送信の確認1件。既存SQLite一覧がS3フォルダカタログと未接続なのが原因。原本の再送や削除は不要。
## Changes
左メニューS3フォルダ、保存完了時の表示ボタン、空一覧からの導線を追加。最新の完了カタログをroot単位で表示。階層・軽量サムネイル・原本詳細・動画controls・原本取得を接続。Mac原本がなければ明示オープン時だけ固定S3版GET、サイズ／SHA-256照合。未完了カタログを公開しない。初期原本閲覧100MiB／原本キャッシュ500MiB。
## Files Changed
local-api/vault/folder_upload.py・app.py、local-api/tests/test_folder_upload.py、web/src/CloudFolders.tsx・FolderUploader.tsx・App.tsx・styles.css、CURRENT・ARCHITECTURE・CODEMAP・contracts/README・手動アップロード文書、この記録。
## Validation
API全54件成功（関連19件、S3版取得はmock）、Web型チェック・ビルド成功。ブラウザで生成素材の完了フォルダ→サブフォルダ→サムネイル→画像詳細成功。既存のMac転送記録は読み取りのみ確認。実AWSへ追加送信・削除なし。文書full・差分空白検査成功。
## Result
S3アップロード済みフォルダを閲覧する導線を実装。再アップロード不要。反映にはMacアプリの完全終了・再起動が必要。
## Remaining Issues
通常のSQLite素材一覧とは別領域。iOS接続・他端末カタログ取得・大容量動画・HEIC等プレビュー・キャッシュ管理UI・予算監視は未実装。100MiBを超える原本はMac元ファイルから開く必要がある。
