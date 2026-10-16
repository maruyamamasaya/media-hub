# 通常送信のHTTP接続再利用とS3要求削減
## Request
HTTP接続の再利用と不要なS3要求を削減する。本人は全件比較を取りやめ、改善版で指定フォルダの通常アップロードを許可した。
## Investigation
既存のclient_factory、条件付きPUT、SHA-256、multipart、通常／暗号化の境界を確認。通常のS3CLI生成経路だけを試行内SDKへ置き換えられる。既存AWSログインはCRTが必要な方式で、公式依存を追加して接続を確認した。指定フォルダには6,535枚中283枚が完了した停止履歴が存在した。
## Changes
S3Pooledを追加。1試行内のSDKクライアントを4ワーカーで共有し、8接続・TLS検証・標準再試行最大3回を使う。完了／停止／失敗でclose。通常の既定転送だけに適用し、閲覧・管理・暗号化の経路は維持。
新規小容量原本の事前HEADと、照合済みコピーから作る小画像の事前HEADを削減。S3が同じSHA-256・版ID・ETagを返したPUTは成功応答で照合し、後続HEADを省略。不十分な応答と結果不明時はHEADで照合、異なるSHA-256は拒否。再開時の原本HEAD、multipart／カタログ照合、全件重複判定、非公開設定確認は維持。
## Files Changed
local-api/vault/s3_pooled.py、folder_upload.py、local-api/requirements.txt、local-api/tests/test_s3_pooled.py、ARCHITECTURE.md、CODEMAP.md、TESTING.md、OPERATIONS.md、CURRENT.md、docs/UPLOAD-IMPROVEMENTS.md、decisions/0026-pooled-s3-upload-client.md、本記録。
## Validation
全API223件成功。その後、結果不明PUTの追加テストを含むSDK関連8件成功。契約生成一致・依存整合成功。実AWSの非公開設定3操作はSDKで0.130秒（接続前のSDK構築時間は含まない）。以前のCLI計測1.245秒とは単発・別時点で、全体の速度比較ではない。
既存履歴に送信／予約中がないことを確認してMac再起動。実画面で本人指定と一致する停止履歴を再開し、uploading状態と完了件数の増加を確認。原本は変更していない。
## Result
新規小容量原本＋小画像は通常6操作→2PUT、途中再開の未完了原本＋小画像は通常6操作→原本HEAD＋2PUT。異常時は追加HEADがある。既存283枚から改善版で通常送信を再開し、処理継続中。全件完了・総所要時間は未確定。
## Remaining Issues
改善前の全件比較はユーザーが撤回し、自動承認審査も最新指示を理由に開始前に拒否したため未実施。比較領域への送信はなく、比較データの削除も不要。通常送信が継続中のためアプリを終了／再起動しない。並列数の設定UI、MB/秒・件/秒の画面表示は今回の対象外。
