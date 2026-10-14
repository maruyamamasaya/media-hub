# iPhone暗号化フォルダの閲覧UI統一
## Request
暗号化フォルダも通常フォルダと同じUIにする。
## Investigation
通常のCloudViewerと暗号化のSealedViewerを比較。暗号化側は名前付きListとNavigationLinkでの個別閲覧だった。
## Changes
表紙付き2列フォルダ一覧、3列の正方形メディア一覧、名前・容量非表示、全画面閲覧、左右スワイプ、写真タップの操作表示切替。鍵の追加読込を折りたたみ。復号・Keychain・背景再ロック・閲覧終了時のメモリ破棄を維持。
## Files Changed
- ios/PhotoHub/SealedViewer.swift
- CURRENT.md
## Validation
Simulatorビルド成功。文書fastとdiff空白チェック成功。統合テストは初回8/9成功（通常画像キャッシュの縮尺比較が失敗）、現在のテストで再実行し9/9成功。
## Result
暗号化閲覧の表示と移動操作を通常フォルダへ統一。
## Remaining Issues
実機への更新と実素材の見た目・左右移動・動画停止・背景再ロックの操作確認は未実施。
