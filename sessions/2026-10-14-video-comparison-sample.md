# 動画のローカル比較サンプル
## Request
30秒の比較サンプルをMac内だけで作る操作をユーザーが承認。
## Investigation
指定動画は1440p/60fps HEVC/AAC。60秒地点から30秒を対象。
## Changes
1080p/60fps H.264/AAC、音声込み約3Mbpsの軽量版と、再エンコードなし原画質の比較用切り出しをGit対象外へ作成。S3送信・原本変更なし。
## Files Changed
docs/VIDEO-DELIVERY.md、CURRENT.md。個人メディアは.local内のみ。
## Validation
原本の前後SHA-256一致。両サンプルの全編デコード、解像度・fps・音声・実容量、faststartを確認。文書fast verifyとgit diff --check実施。
## Result
軽量版11.48MB、原画質版49.45MB（約77%減）、変換・切り出し約16.2秒。60fps維持。原画質切り出しはキーフレームにより約0.083秒長い。
## Remaining Issues
本人による画質・可読性の確認。全編変換・S3派生送信は未承認／未実行。iOS画質選択未実装。
