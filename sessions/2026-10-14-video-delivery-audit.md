# 軽量再生用動画の容量・通信量調査
## Request
原本を保持し、軽量な再生用動画1種類を追加する方式を費用・容量込みで比較。
## Investigation
ユーザー指定の動画1本をローカルffprobeで読み取り。約14分51秒、1,395,110,539 bytes、2560×1440、60fps、HEVC/AAC、平均約12.53Mbps。登録済み送信履歴は画像9件で動画なし。
## Changes
ファイル／フォルダの読み取り専用調査ツール、容量・視聴時間別の費用比較、設計文書を追加。
## Files Changed
scripts/audit-video-storage.py、scripts/tests/test_video_audit.py、docs/VIDEO-DELIVERY.md、CODEMAP.md、CURRENT.md。
## Validation
計算・低ビットレート原本での費用悪化・未計測の3テスト成功。合成動画と指定動画の実解析成功。文書fast verifyとgit diff --check成功。
## Result
音声込み3Mbpsに10%余裕を加えた仮定で派生約0.342GiB、追加保存約1.41円/月。月10時間視聴の転送約13.83GiB／260円、原本平均では約57.74GiB／1,086円。無料枠なし、150円/USD・税10%、東京の確認単価による概算。軽量版は実変換前で画質未検証。
## Remaining Issues
本人確認用の短い変換サンプルと画質選定。対象・容量・権限を示した派生送信の承認。iOS画質選択・自動URL更新・監視の実装。原本変更・変換・S3追加送信は今回未実施。
