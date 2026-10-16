# 現在のAWS構成確認
## Request
このアプリの現在のAWS構成を説明する。
## Investigation
CURRENT、構成・運用文書、現行CloudFormationテンプレート、10月14日の実AWS調査を照合。実AWSで東京の3スタックの状態と閲覧Lambda設定を読取確認。
## Changes
作業記録のみ。AWS・製品コード変更なし。
## Files Changed
本記録。
## Validation
CloudFormation読取成功。製品変更がないためテスト未実施。
## Result
photo-hub-storage、media-hub-auth、media-hub-readerの3スタックを確認。Mac送信・Cognito本人認証・HTTP API/Lambda認可・非公開S3直接閲覧の構成。
## Remaining Issues
保存量・請求額・アカウント全体の資源は今回再集計していない。旧文書には未デプロイ等の古い記述が残る。
