# 鍵99フォルダと費用急増リスク調査
## Request
鍵の上限を10から99へ増やし、通常以外の利用・故障・累積も含め全体の費用急増条件を予測する。
## Investigation
共通MAX_LOCKS、Mac保存、JWT後の解除、4KiBのトークン/cookie境界を確認。実AWS読取で128MiB/15秒・予約同時実行数なし、通常20req/s・解除0.2req/s、S3旧版無期限・未完了7日破棄を確認。既存資料・コード・AWS公式課金仕様を照合。
## Changes
99件へ増加し、解除トークンをUUIDバイト列で圧縮。旧list形式は読取互換。同一salt/verifierのPBKDF2を解除リクエスト内で1回に共有。99件保存・解除・cookieサイズ、100件拒否、旧トークン互換のテスト追加。費用の異常利用シナリオと未実装の改善案を専用文書へ整理。
## Files Changed
backend/folder_security.py・tests/test_folder_security.py、local-api/vault/folder_privacy.py・tests/test_folder_privacy.py、docs/FOLDER-LOCK.md・COST-RISKS-2026-10-15.md・COST-PLAN-2026-10-14.md、CURRENT.md、本記録。既存の並行編集は保持。
## Validation
backend39件成功、ローカルAPI186件中185件成功・起動1件がsandbox内で失敗。該当test_desktop.pyは制限外の隔離試験で2件成功。関連folder_privacy8件成功。99件同一検証情報でtoken3036文字・Mac解除約0.071秒（Lambda性能ではない）。文書full verify・差分空白・reader YAML構文を確認。
## Result
ローカルコードと資料を更新。AWS読み取り調査成功。AWSコード配布は自動承認レビューが本番デプロイの明示許可不足として拒否し未反映。個人の鍵設定・素材・AWS制限は変更していない。
## Remaining Issues
AWS反映の本人承認、Mac再起動による反映、本人99件操作、異なるsalt99件の実Lambda性能。費用防止案は調査のみで未実装。確定請求・通常動画転送・通知受信・アカウント全リージョン棚卸しは未確認。Swift/iOS/Webは変更せずビルド未実行。
