# 6桁フォルダPINのAWS反映
## Request
既存閲覧APIへの6桁PIN対応の反映を明示承認。
## Investigation
既存media-hub-readerスタックUPDATE_COMPLETEを確認。
## Changes
既存非公開S3へコード成果物を保存し、既存パラメーターを保持してスタック更新。メディア送信・削除なし。
## Files Changed
CURRENT.md、docs/FOLDER-LOCK.md、この記録。デプロイ情報はGit除外領域のみ。
## Validation
backend24件成功。CloudFormation更新成功、Lambda Successful、配布コードのSHA256と共通認可コード一致、管理者による既存ライブラリ読取200。実本人PINの解除は未実施。
## Result
既存iPhone入力欄から6桁PINを利用できるAPIを反映済み。
## Remaining Issues
本人がMacを再起動してPINを設定し、iPhoneで非表示・解除・再ロックを確認する。
