# 内容による通常・暗号化の重複送信除外
## Request
名前・保存場所が違っても同じ内容を送信しない。本人指定で通常内／暗号化内を別々に判定。
## Investigation
通常は素材IDとハッシュの既存キーだけを再利用。暗号化は新規計画で別オブジェクトとなっていた。通常の空カタログ公開は最新一覧を隠すため、重複だけの場合は公開しない必要があった。
## Changes
送信直前・履歴再開時にS3保存完了カタログと候補のSHA-256／サイズを比較。同時選択・予約間も除外。通常は過去カタログを含み、同じrootの最新素材を混在追加の一覧へ保持。暗号化は同じ鍵IDのカタログをhelperでメモリ復号し、平文索引はS3へ追加しない。原本欠損・完全削除は再送可、ごみ箱保管中は重複。照合失敗は停止。重複件数を公開DTOとMac／Webへ追加。既存重複は削除しない。
## Files Changed
local-api/vault/upload_duplicates.py、folder_upload.py、encrypted_upload.py、cloud_trash.py、folder_privacy.py、関連Pythonテスト、macos/MediaHubCrypto/main.swift、macos/MediaHubMac/Views.swift、共通契約と生成DTO、関連仕様・構成・探索・検証文書、decisions/0021、本記録。
## Validation
ローカルAPI全185件・backend37件・Swift27件（実AWS fixtureなし1件skip）成功。重複専用15件は改名・移動・同時選択・履歴なし・過去カタログ・予約順・混在追加・途中再開・ごみ箱・欠損・領域別・改ざん拒否・ページングを実helperと模擬S3で確認。Macとhelper・Web・iOS Simulatorビルド成功。契約生成一致・文書verify・diff空白検証成功。初回sandbox内ではloopback子プロセス、PDFKit、SwiftPMキャッシュ出力で失敗し、通常権限で成功。Webは既存Node 16からローカルHomebrew Nodeへ切替して成功。
## Result
機能実装とMacビルド完了。初回は送信履歴25件の全件完了後にMacアプリを再起動。最終Python変更の反映時には新規送信が始まっており、事前チェックの失敗を反映せず終了して通常送信1件を中断させた。本人へ報告。再起動後のプロセス継続と履歴UIを確認。通常は完了20件・確認待ち1件・中断1件、暗号化は完了5件。
## Remaining Issues
中断させた通常送信1件は履歴から再開が必要。現在の可視履歴には再開対象が表示されず、鍵解除を迂回せず終了。実AWSの重複判定操作、画面上の件数表示、追加通信の速度・費用は未確認。複数Macの同時送信の排他は未実装。確定カタログのない未完了素材は履歴から再開する。
