# API通信回数とロック確認
## Request
画像以外のHTTP通信・鍵確認について確認。
## Investigation
通常画像キャッシュ、最大60件の小画像URL一括署名、ローカル権限検査、API応答のロックrevision確認、期限再ロック、既存費用リスク資料を参照。
## Changes
製品・AWS変更なし。
## Files Changed
本記録のみ。
## Validation
コード読取のみ。負荷試験・実AWS再確認なし。
## Result
キャッシュ表示ごとの鍵解除APIは不要。一覧・認可・URL発行の通信は別に存在。PIN解除と署名URL発行は異なる。短期URLは再ロックしても即時失効せず、費用の強制上限もない。
## Remaining Issues
大量利用時の管理情報処理と実費・実測ヒット率は未確認。
