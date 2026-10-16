# フォルダ管理情報の16MiB化
## Request
管理情報を16MiBへ引き上げ、Mac・iPhone・AWSを更新し検証する。
## Investigation
通常送信・暗号化送信・重複検査・ごみ箱・AWSカタログ取得・Mac/iPhone暗号化readerに4MiB制限。暗号化付加分124バイトも16MiBでは316バイトへ変更が必要。AWS同期応答上限を避ける分割取得も必要。
## Changes
Python共通上限・Swift CatalogLimitsを導入。通常公開JSONを1MiBのBase64断片で取得し、SHA-256・offset・上限で復元を検証。各要求で本人・現行フォルダ認可とrevisionを確認。Lambdaメモリ256MiB。既存編集を保持。
## Files Changed
backend/catalog_limits.py・reader.py・ReaderTests、local-apiの送信／重複／ごみ箱と境界テスト、共有CatalogTransfer.swiftとテスト、Mac helper／暗号化閲覧、iOS閲覧と統合テスト、reader.yaml、関連仕様とdecisions/0024、CURRENT・TESTING、本記録。
## Validation
ローカルAPI全201件・backend全42件成功。Swift全35件成功（通常実行では実AWS1件skip）、別途同じ実AWSテストを16MiB暗号化カタログで実行し成功。iOS Simulator統合18件成功。Mac/helperとiPhone実機用ビルド成功。文書full・契約生成一致・diff空白検査成功。初回のローカル通信／Swiftキャッシュ権限制約は適切な実行権限で解消。追加境界テストの期待するエラーと時刻fixtureを修正し、最終検証は全成功。
実AWSは正確に16MiBの通常JSONを16断片で取得・全体SHA-256一致（約30.9秒）、16MiB＋1バイト拒否、本人なし401／別本人403／版不一致409を確認。暗号化16MiB＋316バイトを本人用署名URLの実S3 Range GETから共通Swift readerで復号・カタログ検証。API Gateway未認証HTTPも401。専用合成オブジェクト3版を正確なVersionIdで除去し、残存版・削除マーカーなしを確認。
## Result
AWSは配備中ZIPを退避しreader.pyと新規catalog_limits.pyのみ差し替え、他配備モジュールを保持して更新。メモリ256MiB、反映ZIP全内容とCodeSha256一致を確認。
通常27件・暗号化5件の履歴が全完了と確認してMacを再起動し、更新版のS3フォルダ画面表示を確認。鍵付きフォルダの名前は非表示を維持。Vesperaは既存署名／Keychain権限を照合して上書きインストールし、起動と後続プロセス継続を確認。本人の原本・鍵・送信履歴は変更していない。
## Remaining Issues
本人の今回の大きな実フォルダでの送信再試行と実機画面での閲覧操作は未実施。最大級の通常公開JSONは分割ごとにS3読取・認可・解析を繰り返すため、本試験で約31秒。実素材の構成での速度・メモリは未測定。素材／フォルダ各10,000件、送信20GiB、重複検査64MiBの上限は維持。
