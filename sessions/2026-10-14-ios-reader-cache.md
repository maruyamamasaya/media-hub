# iOS通常画像の閲覧キャッシュ
## Request
一時キャッシュを活用し、暗号化されていない通常ファイルは端末に長期保持してよい。
## Investigation
通常画像はephemeral通信で毎回取得、暗号化閲覧は独立したメモリ内復号。既存DiskCacheの容量制限を利用可能。
## Changes
通常写真・サムネイルをCachesへ最大512MB保存。接続先・本人・カタログ・素材・原本ハッシュ・用途で分離し、表示前のオンライン権限確認と原本ハッシュ照合を維持。64MB目安のメモリキャッシュを追加。ログアウト・接続変更・設定操作で削除、再ロックでメモリ破棄。取得中の削除後に再保存しない。暗号化内容は既存のメモリ内処理を維持。
## Files Changed
ios/PhotoHub/CloudViewer.swift、docs/S3-READER.md、CURRENT.md、本記録。
## Validation
CoreTests/testCacheEvictsOldestOnly 1件成功。文書full verify・git diff --check成功。新しい一時出力先で署名なしSimulatorビルド成功。初回はサンドボックス制限、既存出力先の再試行は残存テストframeworkのInfo.plist欠損で失敗。
## Result
通常画像を再閲覧時に再利用できる実装を追加。実機への更新は未実施。
## Remaining Issues
通常動画はストリーミング継続。新しい画面操作・キャッシュ再利用・再ロックの実機／統合検証は未実施。OSがCachesを削除する場合があり、オフライン閲覧は保証しない。
