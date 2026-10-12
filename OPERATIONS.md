# 開発・運用

Mac・Windowsアプリ試作は [DESKTOP-OPERATIONS.md](docs/DESKTOP-OPERATIONS.md)。既存Web UIをElectronで表示し、独立した試作ライブラリを使う。Mac向け起動は実機未検証。

新しいローカルWeb版の準備・起動・バックアップは [WEB-OPERATIONS.md](docs/WEB-OPERATIONS.md)。ルートの `scripts/setup-web.ps1` → `scripts/start-web.ps1` で `http://127.0.0.1:8765` を開く。Webと既存iOSの保存領域は別で、自動移行・同期は未接続。以下の手順は既存iOS版。

## Local Development
`ios/PhotoHub.xcodeproj` をXcodeで開き、PhotoHub schemeでiPhoneシミュレータへ実行する。Xcode 26.6で確認、対応iOS 17以上。XcodeGenは `ios/project.yml` からの再生成時だけ必要（生成済みプロジェクトを含む）。

アプリの設定は既定で「開発用ローカル保存」。写真タブの＋で取り込み、設定から未完了アップロードを実行する。ローカルDB・pending原本・DevelopmentObjectsはアプリのApplication Support/PhotoHub、派生キャッシュはCaches/PhotoHub。開発用保存は同じ端末のため、容量解放・再インストール復元の代わりにはならない。

iOSの「設定 → フォルダ同期 → フォルダを追加」からiCloud Drive／このiPhone内の画像フォルダを選択する。登録時に同期し、以降は「同期する」で反映する。AWS設定・ログインは不要。原本と制限・確認手順は [iOSフォルダ同期](docs/IOS-FOLDER-SYNC.md)。AWS接続は現在保留。

開発フォルダでのローカル検証は `sh scripts/verify.sh`。テストの一時オブジェクトはOSの一時ディレクトリに生成し終了時に除去する。アプリのローカル保存を確認するには `xcrun simctl get_app_container <Simulator ID> personal.photohub data` で場所を取得する。個人の写真やJSONをGitへ追加しない。

## 実機インストール
1. Xcodeでプロジェクトを開き、Signing & Capabilitiesで自分のTeamを選ぶ。
2. Bundle Identifierを自分だけの一意な値にする。再生成する場合はproject.ymlにも反映する。
3. iPhoneを接続し信頼・Developer Modeを有効にして、実行先をそのiPhoneにする。
4. 実行して写真アクセスを許可し、取り込みを試す。限定アクセスでは取り込み対象も許可する。
5. Personal Teamはプロファイルが7日で失効する。長期利用には開発者プログラムの開発配布を検討する。

[Appleの説明](https://developer.apple.com/help/account/basics/about-your-developer-account)。App Store公開は初期範囲外。

## Environment Variables / Database Setup / External Services
アプリのSQLiteは自動生成。クラウド設定はAPI URL、Cognito domain、Client ID、本人sub（全て秘密鍵ではない）。refresh tokenはKeychainへ保存し、端末間移行しない。AWS長期秘密鍵はアプリに設定しない。

Lambdaは `BUCKET` と `OWNER_SUB` が必須。JWTはAPI Gatewayが検証、LambdaでもOwnerSubに限定する。設定未完了ではクラウド処理は失敗する。本番認証を外す手順はない。

## Build / Deploy
- ビルド・テスト: [TESTING.md](TESTING.md)
- AWS構成・費用: [設計案](docs/DESIGN.md)
- AWSセットアップと承認対象: [AWS-SETUP.md](docs/AWS-SETUP.md)
- 実機の仕上げ: [DEVICE-CHECKLIST.md](docs/DEVICE-CHECKLIST.md)

AWSリソースはまだ作成していない。AWS CLI / SAM CLIは現在の環境で未導入。テンプレートはYAML構文を確認したが、CloudFormation/SAMの意味的検証と実AWS検証は未実施。

## バックアップ・機種変更
全写真のアップロードと削除を完了してJSONバックアップを保存し、成功表示を確認する。新端末・再インストール後はAWS設定を入力し本人ログイン → 空のライブラリに復元。復元は正常バックアップ時点までで、未送信写真・以後の整理変更は含まれない。S3欠損画像は読み込みエラーとして表示する。

開発用ローカル保存からAWSへの自動移行は未実装。試用後はJSONや原本を必要に応じて保全し、空のライブラリで本番設定を始める。開発用キーとAWSキーを混在させない。

## Troubleshooting
- 原本へアクセスできない: 設定で写真へのアクセスと選択した資産の許可を確認する。
- 未完了アップロード: 通信と本人認証を確認して再試行。前景実行のみ。再起動後も状態が残る。
- AWS削除予約: 署名PUTの期限切れを待つため6分後に削除を再試行する。S3のtombstoneは再署名を禁止し、削除済みIDの再利用を防ぐ。
- 復元できない: 空DBか、同じ本人subか、バックアップの全写真が保存完了かを確認する。
- オフライン: DBと保存済みキャッシュを表示する。未キャッシュ画像は取得できない。
- 容量不足: 既存原本は勝手に消さず、キャッシュを削除する。pending原本の救済には写真ライブラリの元写真も残す。
- Xcodeのsandbox/cacheエラー: 通常のローカルXcode環境で実行する。エージェント環境では標準キャッシュ利用の権限が必要な場合がある。
- 署名なしDebugビルドを既存資産でオフライン署名する場合: PhotoHub.debug.dylib／__preview.dylibなどの内包ライブラリも先に署名し、アプリ全体を最後に署名する。ライブラリを個別に検証し、インストール後はlaunch成功だけでなく後続のprocess一覧で動作継続を確認する。詳細は [実機更新記録](sessions/2026-10-12-ios-folder-deploy.md)。

`.gitignore`で.env、開発データ、Xcode個人設定を除外する。サンプルにも秘密値を記載しない。
