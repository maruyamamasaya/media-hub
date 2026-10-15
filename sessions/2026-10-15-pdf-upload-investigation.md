# PDFアップロード対応確認
## Request
このアプリのS3送信でPDFを扱えるか、暗号化送信を含めて確認。
## Investigation
folder_upload.pyのEXTENSIONSに.pdfはなく、scanで対象外拡張子をスキップする。encrypted_upload.pyのscanも同じFolderUploads.scanを使用する。
## Changes
実装変更なし。調査記録のみ。
## Files Changed
この記録のみ。
## Validation
通常・暗号化のスキャン経路をコードで確認。テスト・実S3送信は未実施。
## Result
現状は通常送信・暗号化送信ともPDFは対象外。
## Remaining Issues
PDF対応には追加実装が必要。実装依頼はまだ受けていない。
