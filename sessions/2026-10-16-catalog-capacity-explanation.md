# フォルダ管理情報上限の説明
## Request
送信前の4MiB超過警告の意味を確認。
## Investigation
folder_upload.pyのcheck_catalog_capacityとUPLOAD-IMPROVEMENTS.mdを確認。
## Changes
実装変更なし。素材本体ではなく名前・階層等の管理JSONの上限であり、通常送信はVersionId最大長等を保守的に予約することを説明。
## Files Changed
この作業記録のみ。
## Validation
実装と仕様文書の照合。説明のみのためテスト未実行。
## Result
選択する親フォルダを小さい子フォルダ単位へ分ける対処を案内。
## Remaining Issues
実際に選択されたフォルダの件数・見積もりサイズは未確認。

## 追加調査
上限拡張の可否を確認。4MiBは送信側だけでなく、backend/reader.py、重複確認、ごみ箱、Mac暗号化helper、Mac/iPhone暗号化閲覧にも存在するアプリ内制限。拡張する場合は送信・閲覧・管理経路を揃えて検証し、AWS閲覧APIと各アプリへ反映する必要がある。実装変更は未実施。
