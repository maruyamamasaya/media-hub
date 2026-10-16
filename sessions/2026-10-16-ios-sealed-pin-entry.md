# iOS暗号化閲覧の2段階PIN入口
## Request
隠したフォルダの解除後、設定に暗号化ファイルと暗号化お気に入りの入口を表示。同じPINを使い2段階で入る。デプロイは後日。
## Investigation
暗号化ファイルは「見る」、暗号化お気に入りは通常お気に入り内にあり、隠したページ解除後は追加確認がなかった。共通PIN画面はKeychainのPIN照合成功後のみopenを実行する。
## Changes
設定内に2入口を集約。各入口は同じ共通PIN画面で再照合し、シートを閉じてから閲覧へ遷移。再確認ではPIN新規作成を禁止。取消・照合失敗では遷移しない。ログイン・隠したページ・セッションの継続を確認。暗号化一覧の鍵読取前と通信後にも認可状態を確認。鍵の取り込みは再確認後の閲覧画面から利用。
## Files Changed
Sources/PhotoHubCore/HiddenPagePIN.swift、ios/PhotoHub/CloudViewer.swift、SealedViewer.swift、Favorites.swift、docs/ENCRYPTED-UPLOAD.md、SHARED-FAVORITES.md、CURRENT.md、本記録。
## Validation
Swift42件（実AWS1件skip）は失敗なし。iOSビルド成功。iOS統合27件成功。初回は既存画像プレビュー破棄確認1件が失敗し、同じテスト群の再実行で全件成功。文書検証とdiff空白確認成功。PINの実入力による画面遷移確認は未実施。
## Result
2段階の入口を実装。実機インストール・デプロイは未実施。
## Remaining Issues
実機のPIN入力、取消・誤入力、背景再ロック後の画面遷移は手動確認が必要。
