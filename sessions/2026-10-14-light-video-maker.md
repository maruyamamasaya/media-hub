# Macの軽量動画作成画面
## Request
軽量版を手軽に作れるようにする。
## Investigation
既存MacはElectron＋React＋ループバックFastAPI。原本を保持し、Mac内の派生生成とS3送信を分ける。
## Changes
「軽量版を作る」メニュー、ネイティブ動画選択、確認・手動作成・進捗・停止・再試行・履歴・再生・取り出しを追加。1080pまで、元fps維持（60fpsまで）、H.264/AAC約3Mbps、faststart。原本変更・HDR・長さ・容量の検証、未変更原本の履歴再利用。終了時停止・中断復旧・ディスク確認。AWS設定・送信変更なし。
## Files Changed
local-api/vault/light_video.py、app.py、local-api/tests/test_light_video.py、test_vault.py、web/src/LightVideoMaker.tsx、CloudApp.tsx、App.tsx、desktop/main.cjs・preload.cjs、契約・生成DTO・生成スクリプト、関連正本文書。
## Validation
ローカルAPI全60テスト、Web型チェック・ビルド、Swift全12テスト、契約生成一致、文書full verify、JS構文、git diff --check成功。承認済み30秒サンプルの実変換で1080p/60fps・サイズ・原本ハッシュ・重複抑止を確認。隔離ブラウザで確認→作成完了→再生を確認、画面保存。更新Mac起動とメニュー表示を確認。ネイティブ選択ダイアログは操作ツールがウインドウを失うため手動確認が残る。
## Result
Mac内だけで軽量版を作れる。S3へ自動送信しない。指定原本の全編変換は行っていない。
## Remaining Issues
S3の派生保存・認可・カタログ参照・iOS画質選択は未実装。完成結果は作業領域に残りMac容量を使う。HDR・60fps超は拒否する。突然の強制終了で子変換プロセスが残る場合の追加検証。
