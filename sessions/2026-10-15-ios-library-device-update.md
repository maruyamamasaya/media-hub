# ライブラリUIの実機更新
## Request
新しいiOS UIを実機にも更新する。
## Investigation
Vespera（iPhone 17e）を照合。既存署名プロファイルの有効期限・端末・証明書・Keychain権限を確認。
## Changes
最新の本体ソースをiphoneos向けビルド。既存の接続設定と権限を引き継いで内包ライブラリとアプリへ署名。personal.photohubへ上書きインストール。
## Files Changed
CURRENT.md、本記録。ビルドと署名コピーは一時領域。コード変更なし。
## Validation
実機ビルド成功。codesign strict／deep検証成功。installとlaunch成功。後続のprocess一覧でPhotoHub PID 39608の存在を確認。直前のSimulator統合13テスト成功済み。
## Result
Vesperaを新UIへ更新し起動。アンインストール・データ初期化なし。
## Remaining Issues
実素材の見た目、指でのスワイプ、PIN操作は本人確認待ち。
