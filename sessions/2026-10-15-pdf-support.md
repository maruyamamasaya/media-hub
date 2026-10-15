# PDFの通常・暗号化送信とMac／iPhone閲覧
## Request
PDFを暗号化アップロードも含めて扱い、MacとiPhoneで開いて読めるようにする。
## Investigation
通常と暗号化は同じ拡張子スキャンを使用。既存カタログと本人限定GET APIはPDFのMIMEを許容し、AWSの変更は不要。表示は画像専用だった。
## Changes
PDFを送信対象へ追加。閲覧のメモリ上限に合わせて100MiB超を送信前に拒否。既存Mac helperで先頭ページを描画し、既存の小画像サイズ制限と暗号化経路を使用。共通PDFKitビューで全ページの縦スクロール・拡大縮小・PDF自身のパスワード入力。通常／暗号化の両端末に接続し、暗号化の復号内容はメモリのみ、終了時に破棄。iPhoneの写真／動画専用一覧は従来の対象を維持。
## Files Changed
Sources/PhotoHubCore/PDFReader.swift、Mac送信helper・Views/Gallery/SealedViews、iOS CloudViewer/SealedViewer、local-apiのfolder_upload/encrypted_upload/pdf_preview、PDFのPython・Swift・iOSテスト、backend readerのPDF認可テスト。CURRENT・ARCHITECTURE・CODEMAP・TESTING・暗号化仕様・PDF仕様・本記録。既存の未コミット変更を保持。
## Validation
標準Mac検証成功: ローカルAPI168件、backendは追加後37件、Swift25件（明示実AWS fixtureの1件skip）。MacのPDFKitホストビュー・2ページ目への移動・パスワード保護・暗号化往復成功。iOS Simulator統合16件成功、実機ビルド成功。初回iOSのラベル参照エラーを修正。sandbox下のSimulator／AppKit検証は権限を得た実行で解消。文書verify・diff空白検証成功。
模擬S3で通常原本の照合付き取得と一時ファイル削除、暗号化原本・表紙・管理情報が暗号文だけで送られること、サイズ超過拒否を確認。iOSでPDF取得のSHA-256不一致・再ロック拒否・2ページ描画を検証。
## Result
Macを再ビルドして再起動（終了直後の起動競合は再試行で解消）。既存の証明書・プロファイル・Keychain権限を引き継いでVesperaへ上書き更新。起動成功とPhotoHubプロセス継続を確認。アンインストール・データ初期化・AWS変更なし。
## Remaining Issues
実AWSへのPDF送信と実素材の表示、実機の指でのスクロール／拡大操作は未確認。PDF編集・注釈保存・100MiB超の部分読み込みは未対応。詳細は[PDF仕様](../docs/PDF-SUPPORT.md)。
