# 99フォルダの本番反映と優先費用対策
## Request
99フォルダ対応をAWS本番へ反映し、費用急増リスクの高い部分から対策する。
## Investigation
共通鍵処理・送信前カタログ全取得・CLI自動ページング・iPhone原本先読み・通常動画の計測漏れを追跡。既存署名・Keychain権限と送信履歴の状態を確認。
## Changes
AWSは配備中のZIPを保存しfolder_security.pyだけ差し替え、revision付き更新。ローカルはカタログ本文の版/ETag/保存先付き64MiBメモリ再利用、暗号文維持、1検査64MiB/2,000件の停止と明示ページングを追加。同じ検査で確認済みの内容の原本HEADを省略。先読みを1枚10MiB・1窓20MiB・起動から再ロックまで試行累計100MiBへ制限。通常iPhone動画の取得可能なアクセスログ受信量を増分記録し、暗号化との二重加算を回避。費用画面の計測説明を更新。
## Files Changed
local-api/vault/upload_duplicates.py・folder_upload.py、tests/test_upload_duplicates.py、ios/PhotoHub/CloudViewer.swift・PhotoHubTests/IntegrationTests.swift、Sources/PhotoHubCore/UsageActivity.swift・UsageDashboard.swift、Tests/PhotoHubCoreTests/UsageTests.swift、関連仕様・CURRENT・TESTING、decisions/0022、本記録。以前からの編集は保持。
## Validation
AWS配布コードのハッシュ一致、本人/library200、未認証401。ローカルAPI全193件成功（重複検査22件を含む）。Swift28件成功・うち実AWS1件skip。iOS Simulator統合17件成功、Mac/helper・iPhone実機ビルド成功。既存プロファイル/端末/署名/Keychain権限を照合し署名検証成功。文書full verify・git diff --check成功。
## Result
AWS99件対応を本番反映。通常23件・暗号化5件の履歴は完了で送信中なしを確認しMac再起動、更新プロセスと画面の存在を確認。初回再起動は終了直後のLaunchServices -600で失敗し、待機後に起動成功。Vesperaは既存データ保持で上書きインストール成功。起動要求は端末ロックで拒否され、起動成功とは報告しない。個人素材・鍵設定・AWS制限の変更や削除は行っていない。
## Remaining Issues
本人の99件操作と異なるsalt99種類のLambda負荷試験、Vesperaのロック解除後の起動・実素材の体感、実動画のアクセスログと請求転送量の比較。通常動画・PDFの反復取得、署名URL悪用、旧版/孤立/ごみ箱蓄積は強制上限なし。最新索引、AWS転送照合、整理候補、異常時停止手順は残課題。新しい有料監視は導入していない。
