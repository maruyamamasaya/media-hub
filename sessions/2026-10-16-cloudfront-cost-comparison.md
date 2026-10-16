# CloudFront費用と現行配信構成の確認
## Request
無料枠消費済みで100KB画像を毎時間1万枚配信する費用と現行構成の確認。
## Investigation
CURRENT、構成資料、閲覧API、インフラ設定を確認。現行は非公開S3の署名GETによる直接取得。CloudFront経由ではない。AWS公式の日本向け料金を参照。
## Changes
製品・AWS設定変更なし。
## Files Changed
本記録のみ。
## Validation
文書・コードの読み取り。実AWS再調査・テストは未実施（実装変更なし）。
## Result
30日で約720GB・720万HTTPS要求。従量課金の無料枠なし、日本向け初段単価と150円/USDでCloudFront約13,608円/月（税別）、S3 GET・保存・認可API等は別。キャッシュヒットでも端末へのCloudFront転送は有料。
## Remaining Issues
実請求、無料枠残量、キャッシュヒット率は未確認。定額プランは別条件。
