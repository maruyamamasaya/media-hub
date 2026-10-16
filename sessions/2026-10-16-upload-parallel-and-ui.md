# Macアップロードの開始待ち・並列処理・暗号化UI
## Request
選択から送信開始までを短縮し、可能な範囲で並列処理する。通常／暗号化の別画面を維持してMacの説明と操作を簡単にする。
## Investigation
全文照合は逐次、全選択フォルダの照合後に予約開始。小容量は2件並列、大容量は単独。小画像は高解像度JPEGを全面展開していた。
## Changes
照合4件・小容量の準備／送信／小画像4件を並列化。JPEGの縮小読み込みを追加。先頭送信中に次の1フォルダを準備し、保存完了後だけ次を開始。停止・失敗・再ロックで後続送信を止める。暗号化は初回鍵準備と普段の追加を分け、準備済みの鍵管理と接続詳細を折りたたむ。送信中の鍵差し替え操作を無効化。詳細は[仕様](../docs/UPLOAD-IMPROVEMENTS.md)・[判断](../decisions/0023-upload-preparation-overlap.md)。
## Files Changed
local-api/vault/folder_upload.py、encrypted_upload.py、test_upload_improvements.py、MacのModel.swift・Views.swift・SealedViews.swift・UploadBatch.swift、UploadBatchTests.swift、および関連正本文書。
## Validation
ローカルAPI全195件成功後、新規テスト追加を含む関連19件成功。Swift全32件成功（実AWS1件skip）。Mac.appと暗号化helperビルド・署名成功。制限環境ではローカル通信/PDFテストが失敗したため、同じ隔離試験を制限外で再実行して成功。通常／暗号化JPEGの向き・320px/50KB上限・EXIF除去・原本保持を確認。合成6000×4000 JPEG、各5回の小画像作成中央値は0.308秒→0.231秒（約25%減、ローカルの単一条件）。アップロード全体の速度を意味しない。
## Result
更新版をビルド済み。現在の通常アップロードに送信中履歴1件があるため、稼働アプリは再起動していない。
## Remaining Issues
実画面での新UI操作・実素材／実AWSの速度測定は未実施。1フォルダ内は全文照合後に送信を開始し、大容量送信は単独のまま。停止後の未準備フォルダは再選択が必要。実素材は試験で送信・削除していない。
