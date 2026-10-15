# 容量と費用のグラフ

2026-10-14。Macの左メニュー「容量と費用」、iPhoneの「設定 → 容量と費用」から開く。

## 保存量と費用

Macの「AWSから更新」でS3 `media-hub/` 配下の全バージョンを集計する。原本・暗号化データ（小画像を含む）・通常小画像・管理情報／配布コード・過去バージョンに分け、旧版とごみ箱を含む。素材の中身は取得せず、名前・キー・端末パス・鍵は集計JSONに保存しない。未完了multipartと削除マーカーの容量、prefix外のAWS配布物は含まないので、全請求対象の容量とは異なる。

保存量と保存費の目安を日付ごとのグラフで表示する。同日の更新は置換し、更新した日だけ最大90件保持する。未更新の日をゼロで補完しない。初回は1点だけで、過去の履歴を捏造しない。保存費は東京・全件STANDARDの場合だけ `$0.025/GiB/月 × 150円/USD × 税倍率1.1` で計算する。現在の量を1か月保持した目安で、転送・API等や無料枠・割引を含む確定請求ではない。別リージョン・別クラスは未試算を表示する。単価の根拠は [費用計画](COST-PLAN-2026-10-14.md)、[AWS S3料金](https://aws.amazon.com/s3/pricing/)。月2,000円は全体の運用目標で、強制課金上限ではない。

Macの更新だけが集計JSONを非公開S3 `media-hub/usage/latest.json` へ共有する。条件付きPUT・SHA-256とサイズのHEAD照合を行い、競合・取得失敗で過去の集計をゼロにしない。バージョニングにより古い集計JSONにも保存料がかかる。自動更新・自動削除は行わず、更新時のLIST/GET/HEAD/PUTに既存の従量料金がかかる。新しい課金監視サービスやCost Explorer APIは利用しない。

iPhoneは本人認証付き `GET /usage` でその集計を読む。LambdaにはこのJSONだけのGetObject権限を追加し、JWT・owner照合・openidスコープ・no-storeを維持する。未作成は404、権限・通信エラーは別の失敗。保存量は鍵付き・暗号化フォルダを含む総量として表示し、素材名や内容は出さない。

## 端末ごとの通信記録

機能導入後の通信回数と記録済み受信量を、今月の日別グラフで表示する。記録は日本時間・最大90日分。MacとiPhoneは別集計で、通信履歴をS3へ送ったり端末間合算したりしない。

- iPhone: 閲覧API・通常画像・暗号化Range取得のURLSessionタスク指標からネットワーク取引回数と受信本文bytesを記録する。キャッシュ表示は含まず、記録できる再試行・エラー応答も含む。通常動画はAVPlayerが報告した受信bytesの増分を5秒ごとと表示終了時に追加する。通常動画の通信回数・未報告の受信・認証用通信は対象外。暗号化動画の受信はURLSessionのみで計測し二重加算しない。
- Mac: S3CLIの呼出回数とGETが完了したオブジェクトのContentLength、暗号化直接取得のURLSession指標を合算する。CLI内部の再試行・途中失敗の受信・管理APIの本文サイズは対象外。
- 通常／暗号化動画のプレーヤー生成は「再生開始」として別に記録する。実際に視聴した秒数・完走回数ではない。Macの軽量版のローカル再生もここに含む。

端末の接続先／本人（Macは保存先／プロファイル／リージョン）をハッシュ化して集計を分ける。URL・ファイル名・ID・認証情報は記録せず、日付と数値のみを永続化する。iPhoneはUserDefaults、MacのCLI分はprivate作業領域 `usage/`。ログアウト後は閲覧画面を破棄するが集計自体は保持し、同じ本人の再ログイン後に継続する。写真キャッシュの削除は集計を削除しない。

通信回数だけから料金を換算しない。この受信量はAWSの請求転送量ではなく、通常動画の未報告分・他端末・CLI内部再試行等の未計測がある。S3追加リクエストメトリクスは有効化していない。[AWSのメトリクス仕様](https://docs.aws.amazon.com/AmazonS3/latest/userguide/cloudwatch-monitoring.html)。

## 既存予算

Macの更新時に既存 `Monthly-10USD-Alert` の反映済み費用・予測・上限・通知設定件数・登録宛先数だけを読み取る。画面とS3には宛先アドレス・AWSアカウントIDを保存しない。AWSアカウント全体であり、このアプリ単独の請求とは区別する。通知が設定済みでも受信済みと判断せず、「受信は未確認」と表示する。メール送信・宛先変更・新規予算作成は行わない。取得できない場合は未取得の説明を表示する。[AWS Budgetsの読取仕様](https://docs.aws.amazon.com/cli/latest/reference/budgets/describe-notifications-for-budget.html)。

## 検証

`local-api/tests/test_usage.py`、`backend/tests/test_usage.py`、`Tests/PhotoHubCoreTests/UsageTests.swift` で集計・ページング・旧版・履歴更新・接続先分離・欠損／競合／取得失敗・契約・本人認証・固定キー・サイズ上限・日付／同時記録を確認する。実AWSと実機反映の結果は [作業記録](../sessions/2026-10-14-usage-dashboard.md)。

動画の計測は[Appleのアクセスログ仕様](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent)に基づく。実S3動画での報告範囲と請求転送量の比較は未確認。
