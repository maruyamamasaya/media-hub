# フォルダ鍵UIのiPhone実機更新
## Request
作成したUIをiPhone実機へ更新。
## Investigation
接続済みVesperaと既存署名・有効プロファイル・Keychain権限を照合。
## Changes
iphoneosビルド後、既存の本人接続設定を公開Info.plistへ継承。既存証明書と権限で署名し、personal.photohubへ上書きインストール・起動。
## Files Changed
CURRENT.md、docs/FOLDER-LOCK.md、この記録。実機ビルドと署名コピーは一時領域。
## Validation
実機ビルド成功、codesign deep strict成功、install・launch成功、後続process一覧で動作継続確認。
## Result
新しいフォルダ状態・閉じて隠すUIをiPhone実機へ反映。アンインストール・データ初期化・AWS・メディア変更なし。
## Remaining Issues
実画面と本人PINでの解除・閉じて再ロックは本人確認待ち。
