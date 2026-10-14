# 非公開S3サムネイルと全体費用の更新
## Request
端末への長期サムネイル保存を避けて非公開S3方式にし、全体コストも見直す。本人指定は小画像1万枚を月2〜3回、動画月1〜5時間。
## Investigation
閲覧API・IAM・iPhoneは非公開小画像取得に既に対応。Macは原本・小画像をview-cacheへ永続化していた。公開東京価格表と実S3容量・旧版・未完了送信・ログ保持を再確認。
## Changes
Macで最大320px・50KB以下のPNGを生成しメタデータを除去、非公開S3へ条件付き追加・サイズとSHA-256照合。新規送信に統合し、既存向けはロック付き明示ツールとETag条件付き管理情報更新。通常閲覧はS3取得・応答後削除の一時ファイルに切替。小画像は画面離脱時にメモリ破棄し、詳細を閉じるたびの全件再取得を廃止。iOSにも画面離脱時のメモリ破棄を明示追加。原本・既存ローカル素材は変更なし。
## Files Changed
local-api/vault/folder_upload.py・app.py、関連Pythonテスト、backend/tests/test_reader.py、macos/MediaHubMac/Gallery.swift、ios/PhotoHub/CloudViewer.swift、scripts/publish-folder-thumbnails.py、役割別文書、decisions/0015、この記録。
## Validation
verify-desktop成功（local-api78件、backend25件、Swift16件、契約・文書・.appビルド）。iOS Simulatorビルド成功。制限内iOSビルドは標準キャッシュ権限で失敗し、承認環境で成功。後続の小変更は関連Python・Readerテストと文書／差分を再確認。
最終関連テストはFolderUpload31件・Reader11件成功。合成した0.3秒動画で実ffmpegの小画像生成・50KB以下・原本不変更も確認。
実AWSで既存9件の小画像追加・照合成功。iPhone閲覧Lambdaへの本人相当の管理者イベントでカタログ9件のhasThumbnailと小画像URL応答200を確認（API Gateway本人ログインの代替検証ではない）。Mac実画面で9枚の表示を確認。旧閲覧コピー16個を整理し、表示後の旧キャッシュ・API一時ディレクトリが0件であることを確認。
## Result
小画像9枚339,453 bytes（平均約37.7KB）。S3現行1,136,285 bytes、非現行管理情報5,719 bytes、未完了送信0件。原本581,046 bytesは保持。ログ保持7日。新規AWSサービス・IAM変更・公開化・原本再送なし。
原本20GB＋軽量版5GB、月1〜5時間、1万小画像を月2〜3回なら無料枠なしで約180〜310円/月。100GB＋25GBなら約560〜700円/月。150円/USD・税込・小画像50KBの仮定。署名API・管理情報取得・Lambda・ログも付帯余裕に含めた。
## Remaining Issues
実請求額・転送無料枠残量・動画全体の圧縮率は未確認。原本を何度も取得する転送は追加。非対応形式はアイコン。4MiBを超える管理情報は小さいフォルダへ分割が必要。iOSの追加コードは今回実機へ再インストールしていないが、既存iPhone版で非公開小画像は取得可能。OSスワップ・異常終了直後まで残留ゼロは保証しない。
