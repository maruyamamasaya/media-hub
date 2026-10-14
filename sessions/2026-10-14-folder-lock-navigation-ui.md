# 任意の鍵とフォルダ開閉UI
## Request
起動時には鍵なしを表示、隠した名前はPINで表示、開閉時の鍵確認と設定UIを作る。
## Investigation
MacとiPhoneの一覧・階層遷移・状態表示を確認。
## Changes
起動時PIN要求なし、任意解除・空一覧案内・自身の鍵状態を明示。Macのナビゲーション戻りで再ロック。iPhoneの解除中フォルダに「閉じて隠す」。解除状態は全フォルダ共通で破棄する。
## Files Changed
macos/MediaHubMac/Views.swift、Gallery.swift、Model.swift、ios/PhotoHub/CloudViewer.swift、CURRENTとフォルダロック文書。
## Validation
Macビルド・署名、RuntimeTests3件、iOS Simulatorビルド成功。Mac更新版の起動時にPIN画面なし、案内・読み込み表示を実UI確認。
## Result
Mac UIを起動済み。iPhone UIはコードとビルドまで。
## Remaining Issues
本人PINによる解除・閉じて再ロックの実操作確認。iPhone実機更新。AWS・保存済み鍵・メディア変更なし。
