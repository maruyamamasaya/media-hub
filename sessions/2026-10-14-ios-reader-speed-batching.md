# iOS読み込み速度と通信削減
## Request
iOSの遅い読み込みを調査し、実装・テスト・デプロイまで実施。低コストと高速化を両立し、端末キャッシュは1GBまで利用。
## Investigation
共通ゲートが通常カタログ／画像も600msごとに先行予約し、キャンセル後も待ち枠が残る。APIは毎秒2回。各画像の署名で鍵設定と同じカタログをS3から再取得。画像のディスク操作・ハッシュ照合と毎保存時の全体整理がMainActor上で実行されていた。
## Changes
既存キャッシュを保持して上限1GBへ変更。ディスク処理・原本照合・画像読込を専用actorへ移し、全体走査は初期化／容量超過時等だけに削減。同じ画像の同時取得を共有。通常サムネイルは最大60件を既存GET経路で一括署名し、取得中要求と240秒の署名結果を共有。キャッシュヒットでは一括署名も画像GETも不要。キャンセルは予約枠を残さず60ms間隔で開始。再ロック時は画像取得・署名結果を破棄。AWS閲覧20req/s・burst10、PIN解除0.2req/s・burst1維持。
## Files Changed
ios/PhotoHub/CloudViewer.swift、SealedViewer.swift、ios/PhotoHubTests/IntegrationTests.swift、backend/reader.py、backend/tests/test_reader.py、infrastructure/reader.yaml、CURRENT.md、ARCHITECTURE.md、TESTING.md、OPERATIONS.md、docs/S3-READER.md、decisions/0020-ios-reader-batching-cache.md、本記録。既存の未コミット変更を保持。
## Validation
API36件・Simulator統合11件・Swiftキャッシュ削除1件成功、iphoneosビルド・署名deep strict検証成功。30素材の署名要求が1通信、同じ画像12要求が1ダウンロード、メモリ／ディスク再利用が追加通信ゼロ、再ロック拒否を確認。60署名に必要なS3取得は鍵設定1回＋カタログ1回。文書full verify・diff空白確認成功。
Swift追加検証は既存出力先の/tmpと/private/tmp混在でコンパイラ障害、新規出力先で成功。AWS packageは最初の審査で配布先不明として拒否、既存スタック所有と現行配布先を実照合後に承認・実行。CloudFormation UPDATE成功、配布物参照一致、Lambda Active／Successful、閲覧／PIN制限、未認証401と合成別人ID403を実確認。Vesperaへ既存署名・Keychain権限・データを保持した更新install／launch成功、後続のプロセス存在確認。
## Result
AWSとiPhoneへ最終修正版を配布済み。通信回数削減とキャッシュ活用でコスト・速度を同時改善する実装と隔離テストを完了。
## Remaining Issues
実素材を取得する本番検証は、具体的な機密データ取得の承認がないとして自動審査が拒否。素材取得なしの本番検証へ切替。本人端末の実画面での体感速度・実費・通常動画と暗号化素材の長時間再生は未測定。原本表示は未キャッシュ時に原本全体取得・照合が必要。
