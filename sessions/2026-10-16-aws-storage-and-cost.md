# AWS保存容量と反映済み費用
## Request
現在の保存容量と実際のAWS費用を確認する。
## Investigation
2026-10-16 15:46頃（日本時間）、アプリ用S3の全版一覧・未完了multipart、既存予算、Cost Explorerの10月サービス別UnblendedCostを読取。素材本文は取得しない。
## Changes
記録のみ。AWS設定・素材・製品コード変更なし。
## Files Changed
本記録。
## Validation
各AWS照会成功。製品変更なしのためテスト未実施。
## Result
全版合計12,699,386,191 bytes（12.699GB、11.827GiB）。通常原本1,685,973,402 bytes、小画像79,878,584 bytes、暗号化10,931,943,718 bytes。旧版62,487 bytes、未完了multipart0、削除マーカー0。今月のアカウント全体反映済み費用約$1.15643（税込、未確定）。主な内訳Route 53 $1.0076268、S3 $0.0336712063、API Gateway $0.00480875、DynamoDB $0.000324135、税$0.11。他の返却サービスは$0。既存予算の月末予測$1.172。Cost Explorer照会1回（通常$0.01/回）。
## Remaining Issues
サービス別費用はアカウント全体でありアプリ専用ではない。Route 53/DynamoDBの用途、アプリ別費用配分、反映前の利用費用と最終確定請求は未確認。未完了multipartの保存量は0件のため追加なし。
