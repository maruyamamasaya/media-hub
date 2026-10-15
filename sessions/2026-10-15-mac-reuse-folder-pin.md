# Mac鍵設定のPIN入力省略
## Request
既存PINを共通で使い、Macで鍵を付ける時のPIN入力を省く。
## Investigation
フォルダごとにsalt付き検証情報をS3へ保存。暗号化入口の端末PINとは別。平文PINは復元できない。
## Changes
既定ではPIN欄を出さず、既存の検証情報が一種類なら新しい対象にも適用。初回・曖昧な場合は保存せずPIN指定を案内。解除・祖先認可・条件付き保存・再ロックを維持。
## Files Changed
Mac Views/Model、local-api folder_privacyとテスト、CURRENT、OPERATIONS、docs/FOLDER-LOCK、本記録。
## Validation
verify-desktop成功：契約・文書、ローカルAPI160件、backend36件、Swift24件（実AWS1件skip）、Macアプリビルド。初回の制限環境では子プロセス起動テストが失敗し、ループバック可能な環境で再実行して成功。
## Result
開発用Macアプリを更新。AWS設定・実フォルダの鍵・メディアは変更していない。
## Remaining Issues
本人の再起動依頼後、旧プロセスの終了と更新版のS3フォルダ画面表示を確認。実PINでの鍵設定操作は未実施。過去に同じPINを別々に設定した鍵でもsaltが異なる場合は自動共通化しない。
