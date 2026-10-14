# 検証方法

## Test Strategy
新Web/APIは [Web段階プロンプト](docs/web-phases/README.md) の検証条件に従う。ローカルAPIの原本照合・重複・失敗回復・ごみ箱・所属・競合・契約をunittest/TestClientで確認する。テスト領域は `.local/test-runs` 内のTemporaryDirectory。iOSの未実行ゲートは [共通仕様](docs/IOS-WEB-CONTRACT.md)。

SQLite・キー・バックアップ・転送・キャッシュはSwift Packageのユニットテスト。署名APIはPythonのmock S3テスト。iOS統合テストは実際のPNG生成・派生生成・保存・復元・削除をローカルオブジェクト保存で確認する。AWS結合と実機特有の挙動は [DEVICE-CHECKLIST.md](docs/DEVICE-CHECKLIST.md)。

## Mac SwiftUI / Web Validation
現行Mac版は `sh scripts/verify-desktop.sh`。契約・文書・ローカルAPI・backend・Swift全テスト・開発用.appビルドを確認する。SwiftのRuntimeTestsは一時領域で認証拒否、同じ領域の二重起動拒否、終了・再起動を実子プロセスで検証し、AWSへアクセスしない。loopback bindが可能な実行環境が必要。

Macのタイル変更では、容量非表示・タイトル10pt・正方形、ファイルクリック、左右ボタンと矢印キー、先頭/末尾、連続移動、Escで一覧復帰を確認。CloudLibraryTestsで非公開S3小画像取得・50KB上限・透過／縦横比・EXIF除去・破損拒否・応答後一時ファイル削除・条件付き追加と原本不変更を検証する。ReaderTestsで本人・フォルダ解除なしの小画像URL拒否とprivate/no-store・5分署名を確認する。

Mac画面・操作・配布の未確認項目は [Mac SwiftUI](docs/MAC-SWIFTUI.md)。Windowsアプリ対応は終了し、Electron検証は旧試作用。以下のWeb検証は開発用として保持。

準備後、ルートで `./scripts/verify-web.ps1`。共通型生成一致・文書full・ローカルAPI全テスト・既存署名APIテスト・Web型チェック/ビルド・差分の空白を確認する。Swift/iOSを含まない。

個別入口: `.venv/Scripts/python.exe -m unittest discover -s local-api/tests -v`、`.venv/Scripts/python.exe scripts/generate-contracts.py --check`、webで `npm.cmd run build`。実ブラウザは登録→詳細→整理→検索→ダウンロード→ごみ箱→復元。完全削除と容量不足は隔離テストで確認。390px幅はWebレスポンシブ確認だけ。

性能は `.venv/Scripts/python.exe scripts/benchmark-library.py`。生成64×64 PNG 1,000件を隔離DBへ実登録し、60件API一覧・検索・全ページ重複なしを検証。初期目標は同検証PCでAPI中央値1秒以内。結果は `.local/benchmarks/latest.json`、要約はsessions。実画像の描画・スクロールやiOS性能とは別。

## 暗号化送信と閲覧

`verify-desktop.sh`はMacと暗号化helperを先にビルドし、Pythonの暗号化専用転送テストを省略せず実行する。`test_encrypted_upload.py`で通常履歴との分離・ciphertextのみの送信・原本保持・鍵の非保存・違う鍵による再開拒否・再送抑止・API境界を検証。`test_encrypted_reader.py`は本人認証・不正キー拒否・版固定・5分署名・no-storeを確認。`SealedMediaTests`は復旧ファイル／PBKDF2、AES-GCMの改ざん・順序・ID・鍵の結び付け、境界をまたぐ復号と合成動画のAVAsset読込を検証。

実AWSの合成素材検証は明示実行時だけ`MEDIA_HUB_SEALED_FIXTURE`を指定して`testAWSInteroperabilityWhenFixtureIsProvided`を実行する。通常検証では1件skipであり、実AWS検証の成功を代替しない。テスト用鍵・素材だけで実署名Range GETを復号し、作成した正確な版だけを除去する。本人の鍵作成・復旧パスワード入力・実素材の送信は本人が操作する。

## Fast Validation
アーカイブ変更では、個別切り替え→通常一覧から除外→アーカイブ表示→原本取得→通常へ戻す、選択一括操作、コレクション全体操作、保管状態を指定した検索をブラウザで確認する。DB移行、再起動保持、所属と原本ハッシュ保持、ごみ箱復元、revision/token競合と全件ロールバック、ページ上限を超えるコレクション操作は隔離APIテストで検証する。

```sh
sh scripts/verify.sh --fast
```
文書verifyとPython APIテストを実行。Swift変更では関連するSwiftテストも実行する。

## Full Validation / 標準Verify
```sh
sh scripts/verify.sh
```
文書・Python APIテスト・Swift全テスト・AWS YAML構文・署名なしiOSビルドを実行。Xcode、Swift、Python 3、Rubyが必要。外部依存の取得は不要。`--disable-sandbox` はSwiftPMのビルド実行環境だけの設定で、API認証を無効化するものではない。

iOS統合テストは実行先シミュレータを選んで追加する（重い環境依存処理のため標準verifyと分離）:
```sh
xcodebuild -project ios/PhotoHub.xcodeproj -scheme PhotoHub -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' -derivedDataPath /tmp/photo-hub-xcode CODE_SIGNING_ALLOWED=NO test
```

フォルダ同期はIntegrationTestsでローカル外部フォルダの登録・改名・内容変更・欠損・再指定・再起動・キャッシュ再生成・原本を残す削除を確認する。実iCloudの取得待ちとFile Importerの権限継続は [iOSフォルダ同期の実機確認](docs/IOS-FOLDER-SYNC.md) を別途行う。

## Lint / Format / Typecheck / Unit / Integration / E2E / Build
| 対象 | 実在する入口 |
| --- | --- |
| 文書の必要項目・ローカルリンク・肥大化 | `python3 scripts/verify.py`（軽量は `--fast`） |
| SwiftのTypecheck / Build | Fullのxcodebuild |
| Swift Unit | `swift test --disable-sandbox --scratch-path /tmp/photo-hub-swift-build` |
| Python API Unit | `python3 -m unittest discover -s backend/tests -v` |
| iOS Integration | 上記xcodebuild test、`ios/PhotoHubTests/IntegrationTests.swift` |
| E2E | シミュレータで手動操作、実機チェックリスト |
| AWS | CLI導入後 `sam validate --lint` と実AWS結合検証 |

SwiftLint、独立したSwift format/typecheckコマンド、CI/CD、継続実行するUI自動テストは未導入。WebのTypeScriptはbuildに含む。YAML構文検証はCloudFormationの意味的検証を代替しない。

## 変更別の検証
| 変更 | 必要な検証 |
| --- | --- |
| 文書 | 文書verifyと実コードとの照合 |
| Web / ローカルAPI / 共通契約 | Web Windows Validation + 関連ブラウザ操作。Swift変更はMacでswift testとiOS Buildが別途必要 |
| Swift共有モデル・SQL・転送 | Swift Unit + iOS Build、復元・保存変更はIntegration |
| SwiftUI / PhotoKit / 画像生成 | iOS Build + Integration + 関連画面の操作確認 |
| API / IAM / 認証 | Python API Unit + YAML構文 + SAM検証・実AWS検証（可能な場合） |
| 全体構成 | Full + iOS Integration |

## 文書Verify自体の限界
必須文書・必要項目・README導線・ローカルリンク先・文書の行数を確認する。外部URLの到達性、アンカー、文章とコードの意味的一致は判定しない。詳細を分割する時は役割ごとの正本へリンクする。

S3接続ツールの隔離テスト: `python3 -m unittest discover -s scripts/tests -v`。実接続は [AWS設定](docs/AWS-SETUP.md) の読み取り／1 KiB往復確認を行う。アプリ経由のAWS結合検証は別途必要。

手動フォルダアップロードは `local-api/tests/test_folder_upload.py`。模擬S3で階層・空フォルダ・原本変更・中断・再送抑止・照合・管理JSON確定を検証。ブラウザで確認→親子階層→空フォルダ→手動開始の承認境界を確認。実AWS送信は対象を明示して承認後に追加する。

閲覧専用変更は `backend/tests/test_reader.py`（本人制限・GET限定・キー形状・カタログ所属・版固定・署名300秒・ログ秘匿）、CloudOnlyAPITests（旧ローカル操作410）を検証。CloudViewerRootのSimulatorビルドと本人認証・S3フォルダ・動画URL更新は実AWSデプロイ／実機ログイン後に検証する。

軽量動画は `local-api/tests/test_light_video.py` で原本変更拒否・HDR拒否・重複作成抑止・中断復旧・失敗時原本保持・キャンセル・Range再生・契約を確認する。隔離環境の承認済み30秒サンプルで実ffmpeg作成・原本ハッシュ・1080p/60fps・画面からの作成と再生を確認。

軽量版のS3送信は模擬S3で準備段階のクラウドアクセスなし・対象1ファイル・明示送信確認・照合・カタログ名・重複送信計画再利用を検証する。実AWSメディア送信は対象と保存先を確認して本人の送信操作後に確認する。

フォルダロック: backend/tests/test_folder_security.py・test_reader.py、local-api/tests/test_folder_privacy.py。親子継承、名前／件数／派生／URL非表示、owner・期限・revisionのトークン制限、共有設定不正時拒否、条件付き保存、原本非変更、HttpOnly cookie再ロックを確認。模擬S3の既存テストパスワードで画面の解除・期限後再ロックを確認。新しい本人パスワードの設定・確定と実iPhone解除は本人が実施する。

本人ログイン継続: iOS IntegrationTestsの `testStoredLoginRefreshAndFailurePreserveKeychainUntilLogout` は模擬保存領域・URLProtocolでtoken復帰、一時失敗後の再試行、期限切れ分類、明示ログアウトを検証。署名なしSimulatorの実Keychain操作はerrSecMissingEntitlementで実行不可。実機Keychain継承と再起動時の自動復帰は本人端末で確認する。

## マイショートの追加検証
Web/API標準検証後、`npm.cmd run short-smoke --prefix desktop`で隔離Chromium試験を実行する。合成WebMを派生出力の代わりに配置し、空、重複なし/戻る、ホイール連続、キーリピート抑止、タッチイベント、整理、詳細、動画ミュート/停止、原本を取得しないことを確認する。実FFmpeg変換は別途、対応動画を追加してJPEG thumbnail/MP4 display、変換失敗、ハッシュ一致、再生成、範囲取得を確認する。

iOSではMacでSwift全テスト・iOS Build・IntegrationTests（動画失敗保全と開発用動画保存/復元の追加テスト）を実行し、実機で画像/動画取り込み、縦スワイプ、前へ、アルバム、詳細、タブ/背景で停止、音声、原本保存、復元後の派生だけの取得を確認する。AVFoundation実変換・Dynamic Type・VoiceOver・キャッシュ削除中の再生は未検証。[仕様](docs/MY-SHORT.md)。

S3ごみ箱は `local-api/tests/test_cloud_trash.py` と `backend/tests/test_reader.py`。個別／複数／フォルダ／空フォルダ、復元、原本保持、全版と削除マーカー、正確なキー限定、共有参照拒否、条件付き保存競合、途中失敗・再起動後の手動再試行、鍵解除前の非表示・操作拒否、旧履歴操作による最新版巻き戻り防止を確認する。実AWSの削除試験は専用の合成ファイルだけを使う。本人の素材は試験で削除しない。[操作](docs/S3-TRASH.md)。
