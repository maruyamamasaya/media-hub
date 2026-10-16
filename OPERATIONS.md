フォルダの鍵はMacの「S3フォルダ」で対象を開く→「このフォルダの鍵を設定」。既存の共通PINで入力なしに保存でき、初回・別PINは「PINを指定する」から入力する。iPhoneは「隠したフォルダを開く」で解除する。原本は変更しない。詳しくは [フォルダロック](docs/FOLDER-LOCK.md)。

Macの軽量版作成は上部「軽量版を作る」から動画選択→作成→再生確認。Mac内の派生作業領域に保存し、原本は変更しない。作成後「S3へアップロード · 内容を確認」で保存先・容量・費用を確認し、チェックして手動送信する。軽量版は別フォルダとして保存。条件と容量は [動画配信](docs/VIDEO-DELIVERY.md)。

現在の通常運用は [S3原本・Mac送信・iPhone閲覧](docs/S3-READER.md)。以下のローカル／旧iOS操作は旧版の保全・開発用記録。新UIでは取り込み・同期・ローカル保存を提供しない。

サムネイルは非公開S3に保存する。iOSの通常写真・サムネイルは最大1GBの端末キャッシュを利用し、設定から削除できる（[キャッシュ方針](docs/S3-READER.md)）。暗号化内容の復号結果はメモリのみ。新規送信時に生成し、既存素材への追加と旧閲覧キャッシュ整理は [Macの操作](docs/MAC-SWIFTUI.md)、全体料金の更新見積もりは [費用比較の第9節](docs/COST-PLAN-2026-10-14.md) を参照。

# 開発・運用

Mac版はSwiftUI。通常起動は `sh scripts/start-desktop.sh`。Windows対応は終了。現行手順は [Mac SwiftUI](docs/MAC-SWIFTUI.md)。旧Electron試作は保全用に残す。

新しいローカルWeb版の準備・起動・バックアップは [WEB-OPERATIONS.md](docs/WEB-OPERATIONS.md)。ルートの `scripts/setup-web.ps1` → `scripts/start-web.ps1` で `http://127.0.0.1:8765` を開く。Webと既存iOSの保存領域は別で、自動移行・同期は未接続。以下の手順は既存iOS版。

## 暗号化アップロード

通常／暗号化のフォルダを複数選択・ドラッグしてまとめて確認／予約できる。停止と失敗は残り予約も止め、再開は手動。大容量の分割送信と再開用暗号文の保持は[アップロード改善](docs/UPLOAD-IMPROVEMENTS.md)。

通常の送信とは別に「暗号化アップロード」を使用する。最初にMacでパスワード付き復旧ファイルを保存し、iPhoneで取り込む。本人がパスワードを入力し、鍵・パスワードをチャットへ送らない。操作・制約・復旧方法は [暗号化アップロード](docs/ENCRYPTED-UPLOAD.md)。

## Local Development
`ios/PhotoHub.xcodeproj` をXcodeで開き、PhotoHub schemeでiPhoneシミュレータへ実行する。Xcode 26.6で確認、対応iOS 17以上。XcodeGenは `ios/project.yml` からの再生成時だけ必要（生成済みプロジェクトを含む）。

アプリの設定は既定で「開発用ローカル保存」。写真タブの＋で取り込み、設定から未完了アップロードを実行する。ローカルDB・pending原本・DevelopmentObjectsはアプリのApplication Support/PhotoHub、派生キャッシュはCaches/PhotoHub。開発用保存は同じ端末のため、容量解放・再インストール復元の代わりにはならない。

iOSの「設定 → フォルダ同期 → フォルダを追加」からiCloud Drive／このiPhone内の画像フォルダを選択する。登録時に同期し、以降は「同期する」で反映する。AWS設定・ログインは不要。原本と制限・確認手順は [iOSフォルダ同期](docs/IOS-FOLDER-SYNC.md)。AWS接続は2026-10-14に再開。

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

東京の非公開S3スタックphoto-hub-storageを作成済み。MacのAWS CLIは導入・photo-hubプロファイル認証済み。storage.yamlのCloudFormation検証・デプロイ・1 KiB往復照合を実AWSで実施済み。SAM CLIは未導入。既存iOS用認証・APIテンプレートのSAM検証とデプロイ、アプリのS3接続は未実施。詳細は [AWS設定](docs/AWS-SETUP.md)。

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

MacのS3手動アップロードは「設定 → S3フォルダアップロード」。操作・上限・料金・中断復旧は [手動フォルダアップロード](docs/MANUAL-FOLDER-UPLOAD.md)。元フォルダを保持し、自動同期しない。現行Macではフォルダ選択／ドラッグで準備後に送信する。接続先は設定で確認できる。

## マイショートの動画
Web/Windowsの閲覧用動画生成には、APIを起動する環境のPATHにFFmpeg（任意、ffprobeで寸法取得）が必要。自動導入・同梱はしない。未導入でも原本保管は可能。導入後はAPI再起動と詳細のプレビュー再生成を行う。[対応形式・キャッシュ・iOSとの違い](docs/MY-SHORT.md)。

S3の削除・復元はMacの「S3フォルダ → ごみ箱」。完全削除の対象・過去バージョン・失敗時再試行と、閲覧Lambdaの配布条件は [S3ごみ箱](docs/S3-TRASH.md) を参照。Mac元ファイルは保持する。

容量と費用はMac左メニュー「容量と費用」→「AWSから更新」。保存量と既存予算の集計を非公開S3へ保存し、iPhoneの「設定 → 容量と費用」で読む。通信回数・計測済み受信量は導入後から端末別に記録する。[操作・試算条件・未計測](docs/USAGE-DASHBOARD.md)。

重複確認の通信上限で追加送信が停止した場合は、新規履歴の作り直しや原本削除で回避せず、[検査の通信量制限](docs/UPLOAD-DUPLICATES.md)を確認する。先読み容量制限と通常動画の計測範囲は[閲覧仕様](docs/S3-READER.md)、残る費用リスクは[費用対策](docs/COST-RISKS-2026-10-15.md)を参照。

## 共有お気に入りの配備
`infrastructure/reader.yaml` のGET／POST `/favorites`、Lambdaの `favorites.py` と `reader.py`、お気に入り専用キーのGetObject／PutObject権限を合わせて反映する。既存コード・JWT本人認証・素材の読取専用権限は保持する。

初回は `{"schemaVersion":1,"entries":{}}` のUTF-8 JSONを用意し、AWS CLIの `s3api put-object` で `media-hub/favorites/state.json` に `--if-none-match '*' --content-type application/json --server-side-encryption AES256` を指定して一度だけ作成する。対象バケット／プロファイル／リージョンを既存設定と一致させる。412は既存ファイルを保持して続行し、無条件上書きしない。Lambdaにバケット全体のList権限を与えていないため、保存先未作成時はAccessDeniedとなる場合がある。これを空の情報と解釈して上書きしない。

更新後はCodeSha256・未認証401・別本人403、合成カタログでお気に入り追加／読取／解除を確認し、作成した合成カタログの正確なVersionIdだけを除去する。本人の素材・既存お気に入りの全消去は行わない。2026-10-16に変更セットを確認して既存リソースの置換なしで更新し、初期保存先を条件付き作成、実際のMac／iPhone経路の往復を確認済み。

通常アップロードのHTTP接続プールには `local-api/requirements.txt` の `boto3[crt]` が必要。既存のAWSログイン方式を使うためCRTを含めて導入する。Pythonコード変更の反映はMacアプリ再起動後で、送信中・予約中に再起動しない。SDKで認証期限切れが起きた場合は従来のAWS再ログイン導線を利用する。
