# 手動アップローダーUI整理
## Request
アップローダーを分かりやすくし、必須パラメーター入力を減らす。
## Investigation
旧画面はフォルダ・AWS接続先入力と詳細説明が一続き。既存のmedia-hub接続先は判明済み。
## Changes
選択→確認→アップロードの3段階。既存保存先を初期設定、履歴から直近接続を反映。AWS項目を折りたたみへ分離。件数・容量・費用・送信先・明示開始をカード表示、進捗バーと履歴、階層パンくずを追加。原本保持・手動のみ・送信前確認は維持。
## Files Changed
web/src/FolderUploader.tsx、web/src/styles.css、CURRENT.md、docs/MANUAL-FOLDER-UPLOAD.md、この記録。
## Validation
Web型チェックとビルド成功。ブラウザでフォルダパスだけ指定→接続項目を入力せず確認成功、確認チェックなしでは開始無効、折りたたみと階層表示を確認。文書検証・差分空白検査成功。送信処理を変更しないUI改善のためAPI全再実行は省略。
## Result
通常操作でAWSパラメーター入力不要。S3送信とAWS設定変更なし。
## Remaining Issues
実AWS送信検証は前回の承認待ち。Macネイティブフォルダ選択の実機確認、iOS閲覧、予算通知は別工程。
