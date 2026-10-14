# iOS閲覧キャッシュ版の実機更新
## Request
キャッシュ対応版をデプロイする。
## Investigation
OPERATIONSと既存の署名手順、接続済みVespera、profileの期限・端末・証明書・既存Keychain権限を照合。
## Changes
実機向けビルドを既存署名で署名し、Vesperaへ上書きインストール・起動。運用文書の古いキャッシュ説明を修正。
## Files Changed
CURRENT.md、OPERATIONS.md、本記録。ビルド・署名コピーは一時領域。
## Validation
署名なしiphoneosビルド成功。内包dylibとアプリのdeep strict署名検証成功。install・launch成功、後続のprocess一覧でPhotoHubの動作継続確認。文書verifyと差分空白チェック成功。
## Result
キャッシュ対応版をVesperaへ配布済み。アンインストール・データ初期化なし。AWS更新不要。
## Remaining Issues
通常画像の再利用、設定からの削除、背景再ロックなどの実画面操作は本人確認待ち。
