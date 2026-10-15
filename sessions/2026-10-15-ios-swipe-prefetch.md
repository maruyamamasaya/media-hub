# スワイプ写真の最大10枚先読み
## Request
スワイプで次の写真を最大10枚程度先読みし、全件は取得しない。
## Investigation
ReaderSwipeScreenは現在の素材だけを読み込み、通常写真は共通のメモリ／ディスクキャッシュを使用していた。
## Changes
現在の素材の読み込み後に、以降の写真を最大10枚、逐次取得する。動画・現在位置以前・末尾からの循環は対象外。位置変更／終了／非アクティブ移行でビューの先読みタスクをキャンセルする。キャッシュと認可・原本照合は既存処理を使用する。
## Files Changed
- ios/PhotoHub/CloudViewer.swift
- ios/PhotoHubTests/IntegrationTests.swift
- docs/S3-READER.md
- CURRENT.md
- 本記録
## Validation
iOS 17.4 Simulatorビルド・統合15テスト成功。追加テストで最大10枚、動画除外、末尾、開始前キャンセル、表示時と再先読み時のキャッシュ再利用、移動で1枚だけ追加、再ロック後の取得拒否を確認。文書fast検証・git diff --check成功。最初の試行は模擬API応答のexpiresIn欠落で失敗し、テスト応答修正後に成功。
## Result
先読みは現在位置の先の写真最大10枚に限定。移動時のみ範囲を更新する。
## Remaining Issues
実機更新・指操作による移動／終了時の通信中断確認は未実施。
