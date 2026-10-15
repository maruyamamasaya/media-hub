# iPhoneライブラリの一覧とランダム閲覧
## Request
フォルダ3列・小さなタイトル・S3表記を変更。写真／動画一覧とランダムスワイプの土台、素材インデックスと費用負担を確認。
## Investigation
通常カタログに素材ID・folderId・MIME・SHA-256が存在。既存画像キャッシュと署名URL一括処理を再利用できる。
## Changes
通常／暗号化フォルダ3列、caption名前、ライブラリ見出し。下部5タブ。暗号化入口は解除後の見る画面へ移動。通常横断一覧と上下ランダムスワイプを追加。管理情報は逐次、原本は現在の1件、動画自動再生なし。将来の履歴用に複合素材IDを用意。
## Files Changed
CloudViewer.swift、SealedViewer.swift、IntegrationTests.swift、CURRENT.md、CODEMAP.md、docs/S3-READER.md、本記録。
## Validation
Simulator署名なしビルド成功。統合テスト全件成功（件数は最終ログ参照）。分類・複合素材ID、ピンチ、キャッシュ再利用／再ロック、署名一括化の既存テストを含む。文書verify fastとgit diff --check成功。初回テストはXcode準備停滞で中断し、並列実行を無効化して再実行成功。
## Result
コード実装済み。新しいクラウドDB／サービス／閲覧ログ送信は追加なし。
## Remaining Issues
実機更新と実素材での操作確認は未実施。閲覧時間／再生傾向の永続保存と推薦は今後。暗号化は横断一覧の対象外。AVPlayerの再生前バッファと写真原本取得に既存の通信費は発生し得る。
