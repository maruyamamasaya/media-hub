# スワイプ閲覧のキャッシュ確認
## Request
「スワイプをはじめる」でキャッシュを使うか確認。
## Investigation
CloudViewer.swiftのReaderOverview、ReaderSwipeScreen、loadImage、ReaderImageDiskStoreを確認。写真は通常閲覧と共通のメモリ／最大1GiBのディスクキャッシュを利用。未保存時に取得・保存する。次の原本の先読みはない。動画は署名URLからAVPlayerで読み込み、写真用ディスクキャッシュを使わない。
## Changes
調査記録のみ。
## Files Changed
本記録。
## Validation
コードの呼び出し経路を確認。実装変更がないためビルド・テストは未実行。
## Result
写真はキャッシュを再利用し、キャッシュにない写真は表示時に取得する。
## Remaining Issues
実機でのキャッシュ命中・通信量は未測定。
