# iPhoneの解除入口を設定へ移動
## Request
隠したフォルダを開く項目を設定へ移し、説明文を外す。
## Investigation
一覧・フォルダ内・設定・解除フォームの表示を確認。
## Changes
解除入口を本人ログイン中の設定へ集約。説明文を削減し、PIN入力と処理中・エラー表示を残す。
## Files Changed
CloudViewer.swift、CURRENT、docs/FOLDER-LOCK.md、この記録。
## Validation
iphoneosビルド、既存署名deep strict検証、Vesperaへの上書きinstallとlaunch成功。ソース検索で入口が設定だけにあることを確認。
## Result
実機更新完了。ログイン・Keychain設定を維持、AWSやメディア変更なし。
## Remaining Issues
実画面の配置確認は本人確認待ち。
