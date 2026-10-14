# フォルダ鍵を数字6桁へ変更
## Request
本人指定でフォルダの鍵を数字6桁にする。
## Investigation
共通KDFとMac・Web設定入力、iPhone解除入力を確認。本人ログインの条件とは別。
## Changes
新規鍵はASCII数字6桁。先頭0保持。旧パスワード解除は互換維持。既存ハッシュやメディアを変更しない。
## Files Changed
backend/folder_security.py、関連テスト、local-api/vault/folder_privacy.py、Mac/Web入力案内、CURRENTとフォルダロック文書。
## Validation
backend24件・ローカル鍵3件成功、Mac開発アプリビルド成功。Webビルド・文書検証成功。iOSビルドはキャッシュ書込権限で失敗。iOS案内変更は戻し、既存入力欄を使用（iOSコード変更なし）。
## Result
ローカル実装完了。AWS反映は承認待ち。
## Remaining Issues
AWS Lambda更新の承認、実PIN設定・iPhone解除確認。試行制限は既存の最善努力スロットリング。
