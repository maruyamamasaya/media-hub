# iOSのiCloud Driveフォルダ同期
## Request
AWSを一旦保留し、iOSの設定でiCloud Driveのフォルダを指定して同期する。MyMusicの方式を参考にする。
## Investigation
Photo HubのWeb側の固定Root ID・SHA-256照合方針、既存iOSの写真取り込み・保存経路、MyMusicのFileImportServiceとフォルダ登録方式、Appleのディレクトリアクセス文書を確認。
## Changes
設定のフォルダ登録・再指定・手動同期、bookmark永続化、原本参照と派生生成を追加。改名・移動ではIDと整理情報を維持。変更・欠損・iCloud取得待ちを通知。フォルダ原本はアプリ内削除の対象外。旧Photoのデコード互換と既存保存経路を保持。
## Files Changed
Models.swift、FolderSync.swift、LibraryModel.swift、Views.swift、Xcodeプロジェクト、関連テスト、CURRENT／ARCHITECTURE／CODEMAP／OPERATIONS／TESTING、フォルダ同期文書、実機チェックリスト、この記録。
## Validation
Swift Package 12テスト成功。署名なしiOS Simulatorビルド成功。iOS統合5テスト成功（フォルダの登録・改名・変更・欠損・再接続・再起動・キャッシュ再生成・原本保持、100件上限後の再同期・サブフォルダ・外部symlink除外を含む）。文書full verify・差分の空白確認成功。
初回のSwift／Xcode確認は標準キャッシュ権限で失敗。Swiftは一時キャッシュ、Xcodeは承認済みの標準環境アクセスで成功。SimulatorのUI操作ツールは2回タイムアウトし、画面操作確認は未実施。
## Result
AWS不要のiOSフォルダ参照を実装。原本は選択フォルダ、SQLiteと整理情報は端末内。
## Remaining Issues
実iCloud DriveのFile Provider・再起動後のアクセス・未取得画像・写真への原本保存は実機確認待ち。端末間の整理情報同期、フォルダ参照のバックアップ、EXIF撮影日時と透過派生は未実装。実機への今回の更新インストールは未実施。
