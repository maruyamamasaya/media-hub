# 閲覧キャッシュの確認
## Request
同じ画像を繰り返し閲覧した際のS3再取得の有無。
## Investigation
CloudViewerのメモリ→最大1GiBディスク→S3取得の順序と、キャッシュ識別子・明示削除を確認。SealedViewerの画面離脱時破棄とMac閲覧方針も確認。
## Changes
製品変更なし。
## Files Changed
本記録のみ。
## Validation
コード・資料読取のみ。実端末の通信測定・テストは未実施。
## Result
iPhone通常画像・サムネイルはキャッシュが残り識別子が一致すればS3再取得を省略。暗号化とMac原本は同じ永続キャッシュを使わない。管理情報通信は別途あり得る。
## Remaining Issues
実機でのヒット率と費用削減量は未計測。
