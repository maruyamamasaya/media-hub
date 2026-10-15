# iPhoneピンチと横スワイプの両立
## Request
ピンチ導入後に前後の横スワイプができないため、両立できるようにする。
## Investigation
共通PhoneZoomableImageでpinchGestureRecognizerの接触数が1以上なら横送りを拒否していた。従来テストは指なしの状態だけで、1本指追跡時の拒否を検出できなかった。
## Changes
等倍で1本指を許可し、2本以上またはピンチ認識中（began/changed）は拒否。拡大中は従来どおりパン。通常／暗号化の共通部品に適用。
## Files Changed
ios/PhotoHub/CloudViewer.swift、ios/PhotoHubTests/IntegrationTests.swift、CURRENT.md、本記録。
## Validation
iOS 17.4 Simulatorでビルド・統合14テスト成功。追加テストで1本指、2本指、ピンチ途中の片指解除、拡大中、最小倍率未満のバウンス、等倍復帰を検証。文書fast・diff空白検証成功。
## Result
横送りの過剰な拒否条件を修正。既存の未コミット変更を保持。
## Remaining Issues
実機更新と指によるジェスチャー競合の操作確認は未実施。判定テストは実際のタッチ配送を再現するUIテストではない。
