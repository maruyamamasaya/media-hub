# Mac版SwiftUIへの移行
## Request
本人がMac版をSwiftUIにしたいと希望。Windowsからは基本アクセスしないため対応終了を許可。
## Investigation
既存設計0007、Mac起動、共有Swift DTO、Python API、Reactの送信・閲覧・軽量動画・鍵の境界を確認。既存送信処理を引き継ぎ、画面とアプリ管理をSwiftUIへ移行。
## Changes
Mac専用SwiftUI画面と認証付きPython子プロセス管理を追加。フォルダ選択・内容確認・送信/停止/再開・履歴、S3階層閲覧・画像/動画・保存、軽量動画作成/停止/別フォルダ送信、鍵の設定/解除/再ロックを接続。通常Mac起動を開発用.appへ変更しNode/Webビルドを不要化。Windows起動・検証入口を終了扱いに変更。旧Electronコードと原本は保持。
## Files Changed
macos/MediaHubMac、Package.swift、Tests/MediaHubMacTests、Mac準備/起動/検証・build-mac-appスクリプト、Windows起動/検証入口、現状・構成・探索・運用・検証文書、旧設計注記と判断0007/0014。
## Validation
Swift全14テスト成功後、追加の再ロック試験を含むRuntimeTests 3件成功。PythonローカルAPI65件、backend22件、文書・契約・差分検証成功。標準Full検証と署名なしiOSビルド成功。iPhone 17 Pro Simulatorの既存統合5テスト成功。Mac実機の隔離空領域でS3/アップロード/軽量動画の画面、標準フォルダ選択とキャンセル、ウィンドウ再表示、Cmd+Q後のアプリ終了を確認。
初回の隔離子プロセス試験はsandboxのloopback bind拒否で失敗し、許可された実行環境で成功。起動試験の期待HTTPコードを実APIの401へ修正。開発用.app生成時の空白パス引用を修正して再生成。
## Result
Electronを使わないSwiftUIの開発用Macアプリを作成。既存作業領域・本人AWSプロファイルを継承し、送信・原本変更・削除を自動実行しない。
## Remaining Issues
SwiftUI画面からの実AWS送信・個人メディア再生・大規模/VoiceOver検証は未実施。Python/ffmpeg同梱・Developer ID署名・公証・配布環境検証と旧ショートカット更新は残る。原本100MiB閲覧上限は既存APIのまま。保存料試算はSwiftUI画面へ未移植。起動/メモリの比較数値は未測定。
