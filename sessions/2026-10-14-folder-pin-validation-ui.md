# PIN設定ボタンの案内改善
## Request
「設定して隠す」が有効にならない理由を調査。
## Investigation
新規設定はASCII数字6桁・確認欄一致・処理中でないことが必要。実入力は秘匿されているため原因の断定はしていない。
## Changes
空欄・文字種・桁数・確認未入力・不一致・処理中の案内をMac画面へ追加。PIN自体は表示しない。
## Files Changed
macos/MediaHubMac/Views.swift、この記録。
## Validation
Macアプリビルド・開発署名成功。本人PINの入力・保存は未実施。
## Result
無効理由を画面で確認できる版を準備。
## Remaining Issues
本人が更新アプリを開き直して設定操作を確認する。AWS変更なし。
