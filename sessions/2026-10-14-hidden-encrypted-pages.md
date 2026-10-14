# 暗号化入口を隠す
## Request
暗号化ページを「隠したフォルダを開く」後だけ表示し、端末を閉じた後は再選択する。
## Investigation
既存のMac非アクティブ／iPhone背景での再ロックと復号画面破棄を確認。
## Changes
暗号化入口・iPhone鍵設定を一時表示状態で制御。PIN保護フォルダの解除は別ボタンで維持。再ロック時に表示状態を破棄し、Macの選択ページも戻す。
## Files Changed
Mac Model／Views／SealedViews、iOS CloudViewer、現在地と暗号化操作文書。
## Validation
Mac開発アプリとiOS実機ビルド成功。Vesperaの既存署名で更新・起動。文書検証成功。
## Result
鍵の再読込なしで、毎回明示操作して暗号化入口を表示する。
## Remaining Issues
iPhone実画面での背景復帰確認は本人確認待ち。表示切替は追加のパスワード認証ではない。
