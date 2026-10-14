# Mac手動フォルダアップロード
## Request
論理フォルダとS3原本を分離する方式でMacからフォルダ単位アップロード。常時同期は禁止、手動のみ。
## Investigation
既存Electronフォルダ選択とループバックAPIを利用。既存素材のdevelopment-remote転送は維持し、独立した手動転送とフォルダカタログを追加。AWS設定変更・個人メディア送信は行わない。
## Changes
確認時は端末だけで走査・SHA-256計算。送信先・容量・費用目安・対象を表示して明示開始。階層・空フォルダ・進捗・停止・手動再試行・中断復旧。原本コピーを条件付きPUT、HEADサイズ／SHA-256照合後に管理JSON確定。原本削除・自動送信・自動再開なし。端末のCLI短期認証、公開ブロック・SSE-S3・TLS設定確認、シンボリックリンク拒否。初期上限5GiB/ファイル、20GiB/回。共通DTOを生成。
## Files Changed
local-api/vault/folder_upload.py・app.py、local-api/tests/test_folder_upload.py、web/src/FolderUploader.tsx・App.tsx・generated/contracts.ts、desktop/main.cjs、contracts/、Swift DTO、docs/MANUAL-FOLDER-UPLOAD.md、decisions/0011、現在地・構造・探索・運用・検証文書、この記録。
## Validation
ローカルAPI全48件（新アップローダー13件含む）成功。署名API8件、S3接続ツール6件、Swift12件、Node3件成功。Web型チェック・ビルド、共通生成一致、文書full、差分空白検査成功。ブラウザで確認画面→親子フォルダ→素材一覧、送信前チェック未選択時の開始無効を確認。実AWS送信は生成テスト素材について明示承認待ち。iOS実機未実行。
## Result
Mac手動アップローダー初期版を実装。既存DB・素材への移行や原本削除なし。S3保存料とリクエスト単価は2026-10-14に公式東京価格表で確認、画面の円換算は150円/USD・税10%の仮定。
## Remaining Issues
実AWSで新アップローダーの検証、iOS閲覧・容量／費用表示、既存素材一覧との統合、フォルダ改名移動、予算通知／総利用量制限、限定IAM、サムネイル・動画処理、巨大ファイルのマルチパート、旧原本／古いJSON／クラッシュ残骸の保持規則。今回の費用表示はアプリ総額ではない。
