# PDFの実S3・実機検証と「見る」のヘッダー切替
## Request
テストPDFを実際に暗号化してS3へ送信し、MacとiPhoneで読めることを確認。追加でiOSの写真／動画切替を「見る」のヘッダーに配置。
## Investigation
通常の端末鍵を上書きしないため、専用ランダム鍵と別ID・別Keychainグループの検証アプリを使用。本体のEncryptedUploads／MediaHubCryptoで送信し、共通SealedHTTP／SealedRangeReader／MediaPDFReaderで実S3から取得・復号・表示。既存の本人用鍵・素材は使用しない。
## Changes
iOS「見る」にフォルダ／写真／動画の固定ヘッダー切替を追加。既存の横断一覧処理と取得制限を再利用し、下部は見る／スワイプ／設定へ整理。Vesperaの本体を既存署名・設定・Keychain権限を保持して上書き更新。
## Files Changed
ios/PhotoHub/CloudViewer.swift、CURRENT.md、docs/S3-READER.md、docs/PDF-SUPPORT.md、本記録。合成PDFと画面証跡はGit対象外の.local/test-runs/pdf-live-20261015に保存。検証用署名URL・鍵は一時領域に限定し終了後除去。
## Validation
実S3にPDF原本・表紙・管理情報の3暗号文（計18,456 bytes）を保存。HEADでサイズ・Content-Type・SSE-S3を確認。配備済みReader Lambdaを管理権限による本人コンテキストのイベントで呼び出し、版固定の署名URLを取得。API Gatewayの未認証アクセスは401。
Macと実機Vesperaで実署名URLから取得し、カタログ検証・SHA-256一致・表紙復号・3ページの識別文字列を確認。共有PDFビューの3ページ目への移動・拡大成功を記録し、両端末の表示画像も目視確認。画像証跡に個人素材は含まない。
iOSヘッダー変更後のSimulator統合16件成功、実機ビルド成功。Vesperaへ更新インストールと起動確認。文書verify・diff空白検証成功。
## Result
実S3上の暗号文をMac／実機iPhoneで読めることを共通実装で確認。今回作った正確な3版だけを削除し、版一覧で消失確認。iPhoneの検証専用アプリを削除、Mac検証アプリを終了。本体の鍵・既存S3素材・端末データを保持。
## Remaining Issues
本体アプリでの本人ログイン・PIN／鍵解除・フォルダ選択から始める手動の一連操作は未検証。iPhoneのページ移動と拡大は実機PDFViewへの自動操作で確認し、指ジェスチャーそのものは未確認。本人の鍵を検証用鍵へ置き換えていない。
