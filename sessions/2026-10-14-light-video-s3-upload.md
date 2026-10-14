# 軽量版のS3手動アップロード
## Request
軽量版もS3へアップロードできるようにする。
## Investigation
既存フォルダ送信と本人閲覧APIのカタログ・キー形状・GET権限を確認。別素材の軽量版として登録すればAWS変更不要。
## Changes
作成完了画面に送信準備ボタン、保存先・容量・保存料・確認チェック・開始を接続。軽量版だけを別フォルダへ送信。準備はローカルのみ。同じ計画を再利用し、生成物変更・余分な素材を拒否する。
## Files Changed
local-api/vault/light_video.py・app.py、local-api/tests/test_light_video.py、web/src/LightVideoMaker.tsx・FolderUploader.tsx、関連正本文書、decisions/0013。
## Validation
ローカルAPI全62テスト成功。Web型チェック・ビルド、契約一致、文書verify、git diff --check。隔離ブラウザと模擬S3で履歴選択→送信準備→承認チェック→送信・照合完了を確認。更新Macを再起動。実AWS操作・個人メディア送信はなし。
## Result
軽量版を確認後に既存の非公開S3へ手動送信できる。原本は送信・上書き・削除しない。
## Remaining Issues
実AWSへの新規軽量メディア送信とiPhone閲覧は本人操作後に確認。同一素材内の画質切替は未実装。予算通知は未接続。
