# Photo Hub

個人用の写真・画像素材ライブラリです。ローカルWeb版で追加・整理・検索・閲覧を試せます。既存のSwiftUI写真アプリも保持しています。正式名称は未決定です。

Web版はPC上のSQLiteと専用フォルダへ保存します。AWSリソースはまだ作成していません。WebとiOSの同期は未接続です。

設計は [素材ライブラリ設計](docs/ASSET-LIBRARY-DESIGN.md)、順次実施するプロンプトは [Web開発段階](docs/web-phases/README.md)。使い勝手を検証してからAWS・iOS連携へ進めます。

MacアプリはSwiftUI版へ移行しました。Windowsアプリの対応は終了。起動は `sh scripts/start-desktop.sh`、構成・準備・残件は [Mac SwiftUI](docs/MAC-SWIFTUI.md) を参照してください。

## Web版を試す
WindowsのPowerShellで `./scripts/setup-web.ps1`、`./scripts/start-web.ps1` を実行し、`http://127.0.0.1:8765` を開きます。詳細は [Web起動手順](docs/WEB-OPERATIONS.md)。テスト素材の取り込み、ファイル選択・ドラッグ＆ドロップ、タグ・コレクション・検索、ごみ箱・復元が使えます。

## 既存iOS版を試す
1. `ios/PhotoHub.xcodeproj` をXcodeで開く。
2. PhotoHub schemeとiPhoneシミュレータを選んで実行する。
3. 写真タブの＋から取り込む。
4. 設定で未完了アップロードを実行し、ローカル保存とJSONバックアップを試す。

実機へのインストール・起動・運用は [OPERATIONS.md](OPERATIONS.md)、AWS設定は [セットアップ手順](docs/AWS-SETUP.md)。ローカル保存は同じ端末内のため、アプリ削除や機種変更では失われます。

## 開発情報
- [AI作業ルール](AGENTS.md)
- [現在地](CURRENT.md)
- [システム構成](ARCHITECTURE.md)
- [コード探索の入口](CODEMAP.md)
- [検証方法](TESTING.md)
- [設計案と費用](docs/DESIGN.md)
- [設計判断](decisions/README.md)
- [作業記録](sessions/README.md)
- [実機チェックリストと制限](docs/DEVICE-CHECKLIST.md)
