# Macアップロード1ステップ化
## Request
フォルダアップロードを1ステップにし、確認チェックを除去する。
## Investigation
通常・暗号化は同じUploadScreenを使い、準備後に確認チェックと予約開始が必要だった。
## Changes
選択／ドラッグ後に全対象を準備し、既存予約APIで自動開始。確認チェックと予約選択UIを除去。履歴の開始／再開はボタンだけで実行。送信中の追加選択を無効化し、50フォルダ上限を準備前に検査。
## Files Changed
macos/MediaHubMac/Views.swift、CURRENT.md、OPERATIONS.md、docs/MAC-SWIFTUI.md、docs/MANUAL-FOLDER-UPLOAD.md、docs/UPLOAD-IMPROVEMENTS.md。
## Validation
Mac .appビルド成功。アップロード改善の隔離Pythonテスト15件成功。文書fast検証成功。
## Result
通常・暗号化のフォルダ追加を1操作で送信開始できる開発用.appを生成。
## Remaining Issues
実画面の選択／ドラッグから実AWSへの送信は未実施。実素材は検証で送信していない。起動中アプリへの反映は再起動が必要。
