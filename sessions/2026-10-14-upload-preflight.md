# 送信前の管理情報容量検査
## Request
大量送信、URL発行負荷、暗号化再送、旧経路混在を改善したい。
## Investigation
通常・暗号化とも管理JSONの容量検査は原本送信後。Macは旧Electronと共通のdesktop_run.pyを直接起動する。
## Changes
管理JSONのUTF-8容量を確認・開始・予約時に保守的に検査。通常は全小画像キーとS3版ID最大長を予約、暗号化は専用形状。暗号化の単独・予約確認に容量増加と履歴再開の案内を追加。URL一括化と旧経路整理の対象・依存を資料に記録。
## Files Changed
local-api/vault/folder_upload.py、encrypted_upload.py、local-api/tests/test_catalog_preflight.py、macos/MediaHubMac/Views.swift、docs/UPLOAD-IMPROVEMENTS.md、CURRENT.md、本記録。
## Validation
ローカルAPI全148テスト成功（sandbox内ではdesktop子プロセス試験1件失敗、loopback可能環境で再実行成功）。Mac開発.appビルド成功。文書full verify・git diff --check成功。
## Result
4MiBを超える可能性がある計画を送信前に拒否。既存の未完了計画にも適用。AWSデプロイ・実素材送信なし。
## Remaining Issues
保守的な見積もりのため実サイズが上限以下でも分割を求める場合がある。実画面操作は未確認。URL一括発行・iPhone側利用と旧経路削除は次段階。
