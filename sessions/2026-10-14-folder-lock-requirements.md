# フォルダロックの要件確認
## Request
本人がフォルダ単位で鍵あり／なしを設定したい。
## Investigation
現在は本人JWT照合のみで、フォルダ単位の鍵はなし。端末認証・独自パスワード・ファイル暗号化は保護範囲が異なる。
## Changes
要件確認の質問と未適用の設計案を記録。
## Files Changed
docs/FOLDER-LOCK.md。
## Validation
既存の閲覧経路・署名URL・フォルダ階層を確認。文書verifyとgit diff --checkを実施。
## Result
フォルダ単位で任意ロックする方向を確認。本人の回答で独自パスワードとフォルダ自体の非表示を選択。Macで設定し、iPhoneにも同じ鍵を反映する回答を確認。閲覧APIでの追加認可を含む具体的な変更案と費用例を整理。
## Remaining Issues
AWS変更案の承認、実装・検証・実機確認。AWS設定・データ変更は未実行。
