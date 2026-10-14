# S3を正本にするMacアップロード・iPhone閲覧

2026-10-14。本人専用、非公開、追加費用月2,000円を目標。Macのみ手動アップロード。iPhoneはフォルダ・画像・動画の閲覧のみ。旧ローカルライブラリへの取り込み・同期・整理機能は通常UIから外す。既存データを勝手に削除・移行しない。

## 暗号化用の独立経路

通常とは別のMac手動アップロード・iPhone閲覧を追加。原本・小画像・管理情報を送信前に暗号化し、鍵は端末Keychainへ保管。パスワード付き復旧ファイルで引き継ぐ。既存の通常素材は自動移行しない。[手順と制約](ENCRYPTED-UPLOAD.md)。

## 構成と権限

- Mac: 既存AWS CLI短期認証で非公開S3へコピー送信。手動確認・開始・再試行のみ。入力元を削除しない。
- iPhone: Cognito Hosted UIのCode+PKCE、refresh tokenはKeychain。APIへ本人access tokenを送る。AWSの秘密鍵・CLI認証は渡さない。
- 新規閲覧API: API Gateway JWT検証＋Lambdaの本人sub照合。GETのみ。公開の自己登録は禁止。S3カタログに登録されたIDだけを読み、GET用署名URLを5分だけ発行する。
- Lambdaは既存S3のmedia-hubカタログ・原本・派生を読むだけ。Put/Delete権限なし。iPhoneにアップロード・編集・ごみ箱・原本保存操作はない。
- 原本はS3、Macの元フォルダは送信用入力。Mac表示はS3から取得して照合し、一時ファイルを応答完了・ビューア終了時に破棄する。原本の正本としてローカルを参照しない。
- 一覧は非公開S3の最大320px・50KB以下のサムネイルだけを取得し、原本は取得しない。Macで原本送信時に生成・送信、既存9件にも追加済み。カタログにthumbnailがなければアイコンを表示し、タップした画像だけ原本を取得する。端末の小画像は表示中のメモリだけで保持する。[詳細と既存素材への適用](MAC-SWIFTUI.md)。
- 画像は100MiBまで、サイズ／SHA-256照合後に表示。動画はAVPlayerのRange取得、自動再生なし。署名期限後のシーク等で止まった場合は「再生用の接続を更新」で新URLを得る。再生開始・GET回数だけで転送量は判断しない。
- URLはメモリ内のみ、APIレスポンス・S3 GETはprivate/no-store。画像データはiPhoneに原本ライブラリとして永続化しない。ログアウト／接続先変更で画面・トークン・表示状態を破棄する。

## 実装と検証の範囲

iOSの入口はCloudViewerRoot。旧LibraryModelを起動時に初期化しない。旧iOSの保存データは残すが新UIから操作しない。共通ReadRoot/ReadCatalog/ReadItem/ReadURLはcontractsから生成。Macの通常画面はCloudAppでS3フォルダ・アップロード・設定だけ。desktop APIは旧ローカル操作に410を返す。

閲覧APIは `backend/reader.py`、SAMは `infrastructure/reader.yaml`。Cognitoは `infrastructure/auth.yaml`（Lite）。認証スタックmedia-hub-authと閲覧スタックmedia-hub-readerを明示承認後に作成済み。現在のS3の公開ブロック・TLS・SSE-S3・バージョニングは維持する。旧ユーザーキー用の `backend/app.py` と別の専用ハンドラーで、既存カタログの名前空間だけ扱う。

## 承認済み・適用済みの操作

東京にCognito Lite User Pool＋secretなし公開クライアント＋Hosted UI、HTTP API、128MiB ARM Lambda、読み取り専用IAM Role、保持7日CloudWatchログを明示承認後に作成した。既存S3のmedia-hubプレフィックスをGET／Listする権限だけ付与する。既存バケットの公開設定・暗号化・原本・自動削除規則は変更しない。Lambda配布コードを非公開S3へ置く場合は、そのコード成果物の送信もデプロイ承認に含める。個人メディアの新規送信・削除は対象外。

本人ユーザーを登録済み。最低8文字・大文字・小文字・数字・記号の条件へ承認後に更新した。本人が `scripts/set-reader-password.py` で初回パスワードを設定済み。パスワードはチャット・文書に残さない。

## 料金の仮定と確認

確認日2026-10-14、東京、従量単価、無料枠・クレジット控除なし。1GiB=2^30 bytes。保存はAWSのbinary GB。配信量は計算時に請求GBへ換算する想定。為替150円/USD、消費税10%の仮定で円=USD×150×1.1。為替と税は実請求を保証しない。

| 費目 | 仮定 | 月額USD | 仮定の円 |
| --- | --- | ---: | ---: |
| S3 Standard原本・派生・旧版の合計 | 平均100GiB、$0.025/GB月 | 2.50 | 412.5 |
| インターネット配信 | 請求20GB、無料枠なし、$0.114/GB | 2.28 | 376.2 |
| HTTP API | 10,000回、$1.29/100万回 | 0.0129 | 2.13 |
| Lambda | 10,000回、128MiB・平均200ms、$0.20/100万回＋$0.0000133334/GB秒 | 0.00534 | 0.88 |
| Cognito Lite | 本人1MAU、有料換算$0.0055/MAU | 0.0055 | 0.91 |
| ログ取り込み・保存 | 月10MiB取り込み、7日保持、$0.76/GB＋$0.033/GB月 | 約0.0075 | 約1.24 |
| S3カタログGET・LIST／APIメタデータ配信等 | 利用量による。余裕を含む見込み | 約0.05 | 約8.25 |
| 合計 | 上記シナリオ、無料枠なし | 約4.86 | 約802 |

API関連部分はこの低利用例で約15円/月。固定サーバー・NAT・ALB・WAF・独自KMS・CDN・動画変換・クラウドDBは追加しない。SMSを使わない。メール送信が発生する場合のSES費用、予算通知、月間追加原本、版履歴の増加はまだ実測前。上表は料金上限ではない。

保存100GiBのまま月100GB配信すると転送だけ$11.40、保存込み$13.90（約2,294円）で目標超過。保存400GiB・配信20GBでも約2,035円＋付帯費用。100GB超保存の実容量・月追加量・動画ビットレート・実視聴時間は未確認。動画転送は音声を含むビットレート×配信秒数÷8に先読み・シーク・再取得を加える。無料転送100GBはAWS全体共有なのでこのアプリ専用に割り当てない。無料枠残量・タグ配賦・予算通知は未確認／未設定。

出典: [S3公式料金](https://aws.amazon.com/s3/pricing/)、[S3東京価格表](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-northeast-1/index.json)、[転送東京価格表](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDataTransfer/current/ap-northeast-1/index.json)、[HTTP API東京価格表](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonApiGateway/current/ap-northeast-1/index.json)、[Lambda東京価格表](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSLambda/current/ap-northeast-1/index.json)、[CloudWatch東京価格表](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/ap-northeast-1/index.json)、[Cognito公式料金](https://aws.amazon.com/cognito/pricing/)。

## 配布と残作業

認証と閲覧APIはデプロイ済み。未認証APIアクセスの401と、管理者テストによる既存カタログ一覧を確認。更新アプリをVesperaへインストール・起動し、2026-10-14にユーザーから本人ログイン後のiPhoneでS3閲覧成功の報告を受けた。動画の長時間再生・署名更新の実機検証は未実施。公開接続設定（API/domain/clientID/owner）はiOSのMediaHubReader Info.plistまたは設定から指定。秘密鍵は不要。実機のインストール・本人ログイン・S3閲覧まで確認済み。

原本の自動削除、iPhoneからの原本保存、端末間編集同期は実装しない。既存ローカル原本の整理は別途対象・容量・復旧手段を示し承認後に行う。予算監視・転送制限・プレビュー整備・大容量画像は継続課題。

## iPhoneログインの継続（2026-10-14）
起動時にKeychainのrefresh tokenでaccess tokenを取得し、本人認証状態を復帰する。新しいaccess tokenはメモリだけ。本人ログインボタンも保存済みtokenを先に試し、保存なし・invalid_grantの期限切れ時だけブラウザ認証へ進む。通信・サービスの一時失敗で保存済みtokenを消さない。本人ログアウト／接続変更で削除。ユーザーパスワードは保存しない。フォルダ解除は復帰せず、5分／背景移行／閉じる時の再ロックを維持する。AWSのtoken有効期間は変更していない。

保存領域は従来と同じservice/account・AfterFirstUnlockThisDeviceOnly。保存更新はSecItemUpdate、新規だけSecItemAdd。端末更新は既存Keychainアクセスグループを継承。実機更新・起動済みで、自動復帰の画面確認は本人確認待ち。

## iPhoneの通常閲覧画面

「見る」は表紙付きフォルダを2列表示。表紙はフォルダ以下にある小画像付き写真の先頭、写真がなければ動画の小画像を使う。小画像なし／空ならフォルダアイコン。フォルダ内は子フォルダを表紙付きで表示し、写真・動画を3列の正方形で並べる。素材の名前・容量とフォルダタイトルは省略し、動画は再生マークで識別する。

素材をタップすると全画面で開く。左右スワイプで同じフォルダの前後へ移動。写真をタップすると閉じるボタンを隠す／再表示する。動画は閉じると接続更新を最小限に表示し、移動・終了で停止する。設定は別タブ、接続情報は折りたたむ。小画像は表示中のメモリだけで保持し、本人認証・PINと背景再ロックを維持する。
