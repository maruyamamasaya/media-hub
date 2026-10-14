# 隠したページの入口PIN
## Request
「隠したフォルダを開く」にPINを設定し、別のPIN付きフォルダボタンをなくす。
## Investigation
入口の一時表示状態と既存のフォルダ別解除を確認。端末Keychainの独立したPIN検証情報で保護する。
## Changes
共有PIN設定／入力画面、6桁数字と確認入力、Keychain保管、5回失敗後30秒待機を追加。PIN成功後だけ入口を表示し、既存フォルダの一致PINも解除する。背景中の処理結果では表示を復活させない。
## Files Changed
PhotoHubCore/HiddenPagePIN.swift、Mac Views、iOS CloudViewer、操作文書と現在地。
## Validation
Macアプリ／iOS実機ビルド、差分空白、文書検証成功。Vesperaへ既存署名で上書き更新・起動。Mac実画面で初回6桁PIN／確認欄、未入力時の無効ボタンと暗号化入口非表示を確認。本人PINは代理入力していない。
## Result
入口を1つに統合し、初回は端末ごとに設定、以後はPINで開く。
## Remaining Issues
本人PINの設定・背景復帰での実操作は本人確認待ち。端末間PIN同期と忘失リセット／変更画面は未実装。異なる既存フォルダPINは解除しない。
