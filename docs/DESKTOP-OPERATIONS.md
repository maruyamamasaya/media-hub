# Mac・Windowsアプリ試作の起動と検証

> 2026-10-14: 通常Mac版はSwiftUIへ移行、Windows対応は終了。現行手順は [Mac SwiftUI](MAC-SWIFTUI.md)。以下は旧Electron試作の記録。

2026-10-07時点の開発用Electron試作。既存Webと同じReact UIを表示する。Windows x64で起動確認済み。Mac向け起動とウィンドウライフサイクルを実装したがMac実機は未検証。インストーラー、配布用.app、Python同梱は未実装。

## Windowsの準備・起動
リポジトリルートのPowerShellで実行する。

```powershell
# Web環境がまだない場合だけ実行（詳細はWeb起動手順）
./scripts/setup-web.ps1
npm.cmd ci --prefix desktop
./scripts/start-desktop.ps1
```

Electronは初回起動時にバイナリを取得する場合がある。ネット接続が必要。取得後は通常のローカル起動にネット接続不要。試作は `.venv/Scripts/python.exe` を使用する。別の開発Pythonを指定する場合は `PHOTO_HUB_PYTHON` に実行ファイルの絶対パスを設定する。

ファイル選択とドロップは現Web UIを利用する。編集・表示・終了のOSメニューを追加。「ファイル→保存先を確認」で試作データの場所を確認できる。二重起動は既存ウィンドウへ戻る。API異常停止時はアプリを終了して起動し直す。Mac起動は未検証。

## Macの準備・起動（実機未検証）
Macにリポジトリを用意し、Node.js 22.12以上または24、Python 3.12以上をインストールして実行する。Windowsのnode_modules・.venvをコピーせず、MacのCPUに対応した依存をMac上で取得する。Apple SiliconとIntelそれぞれでの依存導入は未検証。

```sh
sh scripts/setup-desktop.sh
sh scripts/start-desktop.sh
```

python3が古い場合は `PHOTO_HUB_SETUP_PYTHON=/absolute/path/to/python3.12 sh scripts/setup-desktop.sh` のように指定する。APIの既定Pythonは `.venv/bin/python`。実行時の `PHOTO_HUB_PYTHON` 上書きはWindowsと共通。

MacではPhoto Hubアプリメニューから終了する（Cmd+Q）。赤い閉じるボタン/Cmd+Wはウィンドウだけを閉じ、APIを維持する。Dockからのactivateと再起動要求でウィンドウを作り直す。再表示時は画面状態を再読み込みする。トレイ常駐はない。この動作は [Electronのライフサイクル](https://www.electronjs.org/docs/latest/tutorial/tutorial-first-app) に沿った実装で、OS上の確認は下記チェックリストで行う。

Macの検証入口:

```sh
sh scripts/verify-desktop.sh
```

| Mac実機で確認する項目 | 現在 |
| --- | --- |
| arm64/必要ならx64でsetup→起動→画像表示 | 未実行 |
| Cmd+W/赤ボタン後にDockから再表示、素材数保持、APIの重複なし | 未実行 |
| Cmd+QでAPI終了、再起動後の原本と整理情報保持 | 未実行 |
| Finderから追加、日本語名、保存先選択、原本ハッシュ一致 | 未実行 |
| Retina、拡大縮小、VoiceOver、編集のCmdショートカット | 未実行 |
| APIクラッシュ・追加中終了・容量不足・バックアップ/復元 | 未実行 |

Windows上のOS分岐テスト、Macライフサイクルの模擬イベントテスト、シェル構文チェックは、Macの起動・実機成功の代わりにはならない。

## 保存先と終了
- 試用素材: `.local/desktop-library/`（DB、objects、staging）。Webの `.local/asset-library/` と独立。
- アプリ設定: `.local/desktop-profile/`。試作はOS標準データ領域への移行前。
- 自動描画試験の設定: `.local/desktop-smoke-profile/`。通常アプリを開いたままでも独立して検証する。
- 自動描画試験: `.local/desktop-smoke-library/`。生成サンプルだけを追加する。

通常終了はAPI処理の完了を待つ（最大30秒の猶予、35秒後は強制終了）。強制終了時は再起動して取り込み結果・失敗を確認する。ファイル全体のバックアップはアプリとAPI停止後に行う。Webからの自動移行と同期はない。詳細は [デスクトップ設計](DESKTOP-DESIGN.md)、共通バックアップ原則は [Web運用](WEB-OPERATIONS.md)。

## 検証
```powershell
./scripts/verify-desktop.ps1
```

共通Web検証、デスクトップJS構文、API管理コードの統合試験、Electron描画試験を実行する。API管理試験は専用TemporaryDirectoryを使用。実Python子プロセスを使うため、プロセス起動を許可したWindows実行環境が必要。

描画試験は試験素材追加→認証付きAPI一覧と画像取得→サムネイル描画→二重起動抑止→終了を確認する。画面は `.local/desktop-smoke.png`、時間・Electronプロセスメモリは `.local/desktop-smoke-metrics.json`。時間には試験素材追加と二重起動試験を含む。Pythonメモリ・インストーラー容量は含まない。

未確認: 手操作での連続追加・ダウンロード保存・取り込み中に閉じる操作、OS強制終了からの復帰、大規模描画、開発環境のないPC、署名・配布・Mac。原本保存のOS連携、起動中画面・再起動ボタンは次の工程。

## ローカル／開発用リモートの確認
設定にローカル画像フォルダの実パスを表示する。そのフォルダへJPEG/PNG/WebP/HEICを配置し「ローカルフォルダを読み込む」。一覧の所在バッジと「フィルターと並び替え」→「保管場所」で確認する。登録元の画像は通常ファイルのまま参照する。移動・編集の自動追跡は未実装。参照素材の削除は参照元を残す。
新規選択追加は同フォルダへコピー。既存原本は開発用リモートとして表示するが、実体はPC内に保持。S3・端末間共有・リモート転送による容量解放は未接続。[保管設計](STORAGE-DESIGN.md)を参照。

既存のWeb素材を原本コピーなしでアプリから確認する場合は、Webサーバーと起動済みアプリを終了し、Windowsは `./scripts/start-desktop.ps1 -WebLibrary`、Macは `sh scripts/start-desktop.sh --web-library`。Electronの`--web-library`は`.local/asset-library`をそのまま使う。通常起動は従来の独立した`.local/desktop-library`。同じライブラリをWebとアプリから同時に起動しない。この切り替えはデータ移行・同期ではない。Mac実行は未検証。

設定の「フォルダ同期」で画像フォルダを指定し「同期する」。Windowsアプリでは「フォルダを選ぶ」でOSの選択画面を開く。Webでは絶対パスを入力する。移動後は同じ登録先を選び、新しい場所を指定して同期する。一致・新規・改名移動・変更・欠損の結果を表示する。原本は参照し、アプリ管理領域と重なる外部同期先は受け付けない。
素材詳細の歯車から模擬アップロード／ローカルダウンロード。アップロード確認後は参照元も照合して削除する。整理が失敗した場合は同じ設定から再試行。リモート実体はPC内で、AWS送信はない。
バックアップには参照先の外部フォルダも必要。アプリDBだけの退避では外部原本は復元できない。

設定はリンク一覧。「フォルダ同期」「保管場所と使用量」「バックアップ」「テスト用素材」は専用ページで操作し、「設定に戻る」でリンク一覧へ戻れる。

## コード更新後の再起動

Macは⌘W／赤い閉じるボタンではAPIを維持する。更新後は⌘Qで完全終了してから `sh scripts/start-desktop.sh` を実行する。起動済みのまま起動コマンドを再実行すると二重起動抑止により既存アプリへ戻るため、API更新は反映されない。画面だけ再読み込みしてもAPIは更新されない。S3アップロード履歴に保存完了があるのにフォルダ一覧が空なら、再送せず完全終了・再起動を先に確認する。
