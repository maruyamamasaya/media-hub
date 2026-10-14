# 容量と費用のグラフ
## Request
費用と利用量をグラフで見たい。Macへ追加しiOSでも閲覧したい。通信回数をアプリ側で記録する提案。
## Investigation
既存S3／本人閲覧API・予算読取・Mac／iOSの取得経路を確認。通信回数だけではbytesや請求額を再現できず、通常AVPlayerの転送は現在の計測対象外。
## Changes
Mac「容量と費用」とiPhone「設定 → 容量と費用」を追加。保存量／保存費試算の推移・内訳・既存AWS全体予算を表示。Macの手動集計を条件付きで非公開S3へ保存し本人限定GET /usageで共有。各端末の通信回数・計測済み受信bytes・動画開始を日別記録。新しい有料監視・Cost Explorer・通知送信なし。
## Files Changed
usage集計・検証・共通DTO／Swift画面・通信計測・Mac/iOS入口・readerとテンプレート・関連テスト。詳細はdocs/USAGE-DASHBOARD.md。CURRENT、ARCHITECTURE、CODEMAP、TESTING、OPERATIONSと判断0019を更新。
## Validation
ローカルAPI158件・backend34件・Swift24件（実AWS素材1件skip）成功。最初のsandbox内loopback試験は失敗し、制限外の同じ全テストは成功。Mac.app・Simulator・最終iphoneosビルド成功。契約生成・文書full verify・差分空白チェック成功。
実AWSの変更セットはApi／Function／ReaderRoleの変更とusage専用Lambda呼出権限追加のみ、既存資源の置換なし。初回のテンプレート変換で参照が欠落した変更セットはAWS事前検査で失敗、未実行。修正セットを実行してUPDATE_COMPLETE。コードhash一致・既存一覧200・未認証HTTP401・JWT/openid維持・本人usage200を確認。
初回集計は約9.687GiB、現在量を1か月保持する保存費試算39.96円（150円/USD・税倍率1.1、転送等別）。既存予算と登録宛先1件を読取。本人ファイルの内容・通知宛先は共有JSONに保存していない。
Mac更新起動と新メニューをAXで確認。操作ツールのnative pipe接続障害が起き、再初期化後も画面グラフの最終操作・見た目確認は未完了。iPhoneは最終版を既存データとKeychain権限を継承して上書き更新・起動し、後続process一覧で動作継続を確認。Mac最終版も送信／変換中でないことを確認して再起動。
## Result
共有保存量・費用試算と端末ごとの通信記録を閲覧できる実装、AWS API、更新アプリを用意。履歴は導入後の実記録だけ。
## Remaining Issues
通常動画の転送bytes、アプリ単独の確定請求、端末間通信合算、通知の受信確認は対象外／未確認。実画面の見た目は本人確認待ち。検証ツールによるスクリーンショットは取得できなかった。
