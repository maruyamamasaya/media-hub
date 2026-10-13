# 検証方法

## Test Strategy
新Web/APIは [Web段階プロンプト](docs/web-phases/README.md) の検証条件に従う。ローカルAPIの原本照合・重複・失敗回復・ごみ箱・所属・競合・契約をunittest/TestClientで確認する。テスト領域は `.local/test-runs` 内のTemporaryDirectory。iOSの未実行ゲートは [共通仕様](docs/IOS-WEB-CONTRACT.md)。

SQLite・キー・バックアップ・転送・キャッシュはSwift Packageのユニットテスト。署名APIはPythonのmock S3テスト。iOS統合テストは実際のPNG生成・派生生成・保存・復元・削除をローカルオブジェクト保存で確認する。AWS結合と実機特有の挙動は [DEVICE-CHECKLIST.md](docs/DEVICE-CHECKLIST.md)。

## Web / Windows Validation
Windowsアプリ試作は `./scripts/verify-desktop.ps1`。共通Web検証に加え、JS構文、Python子プロセス管理・原本照合・再起動・クラッシュ検出、Electronの画像描画と二重起動抑止を確認する。詳細と未確認操作は [デスクトップ運用](docs/DESKTOP-OPERATIONS.md)。

Mac試作は `sh scripts/verify-desktop.sh`（Mac実行は未確認）。OS分岐のNodeテストはWindowsでも実行できる。MacのCmd+W→Dock再表示、Cmd+Q→API停止、Retina・VoiceOverは同文書の実機チェックリストに従う。

準備後、ルートで `./scripts/verify-web.ps1`。共通型生成一致・文書full・ローカルAPI全テスト・既存署名APIテスト・Web型チェック/ビルド・差分の空白を確認する。Swift/iOSを含まない。

個別入口: `.venv/Scripts/python.exe -m unittest discover -s local-api/tests -v`、`.venv/Scripts/python.exe scripts/generate-contracts.py --check`、webで `npm.cmd run build`。実ブラウザは登録→詳細→整理→検索→ダウンロード→ごみ箱→復元。完全削除と容量不足は隔離テストで確認。390px幅はWebレスポンシブ確認だけ。

性能は `.venv/Scripts/python.exe scripts/benchmark-library.py`。生成64×64 PNG 1,000件を隔離DBへ実登録し、60件API一覧・検索・全ページ重複なしを検証。初期目標は同検証PCでAPI中央値1秒以内。結果は `.local/benchmarks/latest.json`、要約はsessions。実画像の描画・スクロールやiOS性能とは別。

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

## マイショートの追加検証
Web/API標準検証後、`npm.cmd run short-smoke --prefix desktop`で隔離Chromium試験を実行する。合成WebMを派生出力の代わりに配置し、空、重複なし/戻る、ホイール連続、キーリピート抑止、タッチイベント、整理、詳細、動画ミュート/停止、原本を取得しないことを確認する。実FFmpeg変換は別途、対応動画を追加してJPEG thumbnail/MP4 display、変換失敗、ハッシュ一致、再生成、範囲取得を確認する。

iOSではMacでSwift全テスト・iOS Build・IntegrationTests（動画失敗保全と開発用動画保存/復元の追加テスト）を実行し、実機で画像/動画取り込み、縦スワイプ、前へ、アルバム、詳細、タブ/背景で停止、音声、原本保存、復元後の派生だけの取得を確認する。AVFoundation実変換・Dynamic Type・VoiceOver・キャッシュ削除中の再生は未検証。[仕様](docs/MY-SHORT.md)。
