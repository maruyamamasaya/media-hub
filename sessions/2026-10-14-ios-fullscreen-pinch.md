# iPhone全画面画像のピンチ
## Request
全画面画像をピンチで拡大・縮小する。
## Investigation
通常ReaderMediaScreenと暗号化PhoneSealedMediaは固定のscaledToFit表示。左右ドラッグで画像送りを行っていた。
## Changes
共通のUIScrollView画像表示で1〜6倍ズームとパンを追加。等倍では左右スワイプで画像送り、タップで操作表示切替。画像変更と画面サイズ変更で倍率をリセット。画像取得・暗号化の保存方針は既存を維持。
## Files Changed
ios/PhotoHub/CloudViewer.swift、SealedViewer.swift、ios/PhotoHubTests/IntegrationTests.swift、CURRENT.md、本記録。
## Validation
署名なしSimulatorビルド成功（新規一時ビルド領域）。文書fast検証・diff空白検証成功。拡大配置・等倍／拡大時のスワイプ可否・回転の統合テストを追加しテストターゲットのコンパイル成功。実行はiOS 26.5 SimulatorのMach -308起動失敗。17.4再試行もパッケージ解決で停滞し停止、テスト成功は未確認。
## Result
通常／暗号化写真に同じピンチ表示を実装。
## Remaining Issues
実機更新と実際の指操作、統合テストの実行完了は未確認。Macのビューアは今回の対象外。
