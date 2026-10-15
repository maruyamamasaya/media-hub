# Mac S3接続待ちのコード調査
## Request
Mac版でS3接続が遅い理由の調査。
## Investigation
- 通常一覧は保存完了の送信履歴ごとに、ごみ箱状態をS3カタログから直列で同期する。
- 鍵設定は履歴・一覧・各画像の認可で毎回HEADとGETを行う。
- S3操作ごとにAWS CLIを起動。通常画像の取得・照合は共通ロック内で実行し、待ち行列が発生し得る。
- 通常サムネイルは画面から消えるとメモリを解放し、API側も応答後の一時ファイル削除とno-storeを使用する。
## Changes
調査記録のみ。実装・AWS設定変更なし。
## Files Changed
- 本記録。
## Validation
MacModel、Gallery、ローカルAPI、FolderPrivacy、FolderUploads、CloudTrashの呼び出し経路を確認。文書verifyを実行。
## Result
一覧更新と画像表示の両方に通信回数・直列処理による遅延要因を確認。今回の体感遅延の主因と秒数は未確定。
## Remaining Issues
遅い画面・操作の特定と実行時の区間計測は未実施。実AWS通信・実素材取得・性能テストは実施していない。
