# 一覧更新待ちとアップロード操作
## Request
フォルダ読み込みが長く、進捗表示がなくアップロードできない。
## Investigation
「フォルダを読み込み中」はLibraryScreenのbusy表示。一覧取得はS3の保存済みカタログ確認を行い、続くごみ箱取得でも再確認する。復帰時のrelockがrunで全更新を待つため選択が無効になった。実ユーザー画面の待ち対象は表示文言から推定、実通信の計時は未実施。
## Changes
再ロックは即時のcookie／表示破棄だけを行い、pollで一覧更新。refreshingと段階名を操作中busyから分離してスピナー表示。送信履歴をS3一覧より先に反映。ごみ箱取得はごみ箱表示・変更後だけに限定。
## Files Changed
macos/MediaHubMac/Model.swift、Views.swift、Tests/MediaHubMacTests/RuntimeTests.swift、CURRENT.md、docs/MAC-SWIFTUI.md。
## Validation
Mac .appビルド成功。RuntimeTests 5件成功（制限内では子プロセス起動試験が失敗し、loopback可能な権限で再実行成功）。文書fast・差分空白検査成功。
## Result
一覧更新待ちでアップロード選択が無効になる条件を除去し、一覧の待ち段階を表示。暗号化の再ロックは維持。
## Remaining Issues
実素材アップロード・実画面・S3一覧の時間計測は未実施。S3一覧自体のフォルダ数に比例した待ち時間は残る。起動中アプリは再起動で反映する。
