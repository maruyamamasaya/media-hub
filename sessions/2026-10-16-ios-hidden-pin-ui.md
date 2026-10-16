# iOS非表示フォルダのPIN画面改善
## Request
iOSの「隠したフォルダを開く」UIを改善し実装。デプロイは後日。
## Investigation
設定のFolderUnlockControlから共通HiddenPagePINSheetを表示していた。入力欄と横並びボタンだけのUIで、iOSの数字キーボード指定がなかった。
## Changes
iOS限定で鍵アイコン・説明・角丸入力カード・大きな主ボタン・キャンセルのナビゲーションを追加。数字キーボード、半角数字6桁制限、初期フォーカス、初回確認欄への自動移動、キーボードを閉じる操作、処理中とエラー表示を整備。スクロールとシステム色で小画面・文字サイズ・ダークモードに対応する構成。既存のPIN照合・初回作成・Mac画面は維持。
## Files Changed
Sources/PhotoHubCore/HiddenPagePIN.swift、CURRENT.md、本記録。
## Validation
iOS Simulator向けビルド成功。既存iOS統合22件成功。Swift42件は失敗なし、実AWS1件skip。実画面の目視・手動入力確認は未実施。
## Result
実装完了。デプロイ・実機インストールは実施していない。
## Remaining Issues
実機でのキーボード表示、初回設定・解除・エラー時の操作感、Dynamic Type／VoiceOverの手動確認は残る。
