# Mac版SwiftUI

2026-10-14にMac専用のSwiftUI画面へ移行。Windowsアプリの対応は終了。Electron試作のソースは旧版の保全用に残し、通常のMac起動では使用しない。

## 構成
`macos/MediaHubMac/App.swift` → SwiftUI画面・Mac標準ファイル選択 → `MacRuntime` → 既存Python API子プロセス。WebView・Electron・Nodeは不要。S3手動送信・SHA-256照合・軽量動画作成・フォルダの鍵は既存APIを使用する。Pythonとffmpegの置き換えは今回の範囲外。

APIは空きloopbackポートと起動ごとのメモリ内トークンを使う。起動設定はstdinのみ。PID・origin・認証付きstatusを確認後に画面を開く。終了時にstdinを閉じて停止を待つ。API側のライブラリロックで旧版との同時操作を拒否する。

## 準備と起動
MacのXcode/Swift、Python 3.12以上、AWS CLIの本人プロファイルが必要。動画作成にはffmpeg/ffprobeが必要。Finder起動でもHomebrewの標準配置 `/opt/homebrew/bin` と `/usr/local/bin` を子プロセスのPATHへ追加する。

```sh
sh scripts/setup-desktop.sh
sh scripts/start-desktop.sh
```

既にPython環境が準備済みなら起動だけでよい。Node/Webビルド/Electronの導入は不要。生成先は `.local/Media Hub.app`。リポジトリとPython仮想環境を参照する開発用.appで、他のMacへ単体コピーする配布物ではない。

既定は既存の `.local/desktop-library`。旧版を完全終了して起動する。明示的にWebの作業領域を継続利用する場合だけ `sh scripts/start-desktop.sh --web-library`。データ移動・原本削除は行わない。既存の旧アプリ用ショートカットは自動で更新しない。

Cmd+Wは画面を閉じる。Dockから再表示できる。Cmd+QはAPIの停止を待ち、最大35秒後は所有する子プロセスを強制終了する。送信中は画面の停止ボタンで停止してから終了する。

## アプリアイコン
MacとiPhoneで同じ承認済みの深緑と淡いリボン状の抽象図形を使用。原稿は `macos/Assets/AppIcon.png`、Mac用は `AppIcon.icns`、生成指示は `AppIcon-prompt.txt`。16〜1024pxの各サイズと透明な角を保持する。

原稿を更新した場合は `sh scripts/build-mac-icon.sh` でICNSを再生成し、通常のアプリビルドを実行する。build-mac-appはResourcesへICNSを同梱し、CFBundleIconFileを設定する。Finderの情報画面で実表示を確認済み。

iPhone用は同じ原稿から1024px・不透明RGBへ書き出す。透過部分だけ深緑で合成し、図案は変更しない。`swift scripts/render-app-icon.swift ios/PhotoHub/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` で再生成できる。iOSの角丸はOSが適用する。

## 操作
- アップロード: フォルダ選択 → 内容・容量・保存先を確認 → チェック → 手動開始。停止・手動再開・履歴を提供する。原本と空フォルダを保持する。
- S3フォルダ: フォルダ・メディアを正方形タイルで表示。タイトルは下部の10pt・1行のみ、容量・件数は一覧に表示しない。クリックでビューアを開き、左右ボタン／←→キーで同じフォルダ内の前後のファイルへ移動する。最初・最後で止まり、Escで同じ一覧へ戻る。保存はビューアのボタンから標準Save画面を使う。
- 軽量版: 動画選択 → Mac内で作成 → 再生確認・保存 → 別フォルダへの送信を確認して開始。
- フォルダの鍵: 解除・設定・解除設定を提供。解除は最大5分、アプリを離れると再ロック。認証Cookieはメモリのみ。再ロック時に画面と読み込み結果を破棄し、取得中の旧応答を表示しない。

小画像は閲覧済みのSHA-256照合済み原本キャッシュから最大320pxで生成し、透過と縦横比を保持。キャッシュがない画像と動画はアイコンで表示する。一覧から原本を取得せず、ビューアを閉じると小画像を更新する。小画像キャッシュは64MiBまで。

ファイル切替時は前の再生を停止し、一時ファイルを削除。取得中の旧ファイルはキャンセル／再ロックの判定後に破棄する。

メディアの表示時は認証付きAPIから一時ファイルへ取得し、AVPlayer/NSImageで表示する。画面を離れると削除する。S3原本の100MiB閲覧上限は既存APIのまま。動画のストリーミング再生改善は別工程。

## 検証
`sh scripts/verify-desktop.sh` は契約・文書・Python API・Swiftテストと.appビルドを実行。`RuntimeTests`は隔離一時領域で実Python子プロセスの認証拒否・同じ作業領域の二重起動拒否・終了・再起動を確認し、AWSへアクセスしない。

画面確認には、個人データと独立した `.local/native-smoke-library` を使う `open '.local/Media Hub.app' --args --smoke-test` がある。通常版をCmd+Qで終了してから試験用に起動する。送信は自動実行しない。

## 配布前の残件
Python/ffmpeg同梱、Developer ID署名・公証、開発環境のないMacでの検証、Retina/VoiceOver、大量素材の操作、実AWSでの手動送信・メディア表示、旧版ショートカットの切替が残る。今回の.appは開発用のアドホック署名。

React版の保存料試算はSwiftUI画面へ未移植。AWS運用費用は [AWS設定](AWS-SETUP.md) を参照。実測のメモリ・起動時間がないため軽量化の数値効果は未確認。
