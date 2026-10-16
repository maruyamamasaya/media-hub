# 次画像の表示待ち削減
## Request
スワイプ後の画像待ちを、先読みとキャッシュで減らす。
## Investigation
隣ページはメモリだけ参照し、縦送りの先読み結果通知は全窓の終了後だった。画像展開も初描画に残っていた。
## Changes
通常横送りを次の最大3枚へ拡張。縦横とも1枚ごとの先読み完了を通知。隣ページは認可・世代確認付きでディスクを読み、通信しない。画像はバックグラウンドで表示用に展開。10MiB/枚、20MiB/窓、100MiB/セッションと動画・PDF除外を維持。
## Files Changed
CloudViewer.swift、IntegrationTests.swift、S3-READER.md、TESTING.md、CURRENT.md。
## Validation
iOS統合22件・実タッチUI2件、実機向けビルド、文書full検証・diff空白確認に成功。Vesperaへ上書き更新・起動後のプロセス継続を確認。
## Result
保存済み画像の隣ページ復元と先読み逐次反映を実装し、Vesperaへ反映。
## Remaining Issues
実素材・実回線での体感速度は未計測。暗号化原本の先読みは今回追加せず、復号内容の長期保存も行わない。初回通信や予算対象外の画像では待ちが残る。テスト専用アプリの削除は対象SimulatorがShutdownのため未実行（本体への影響なし）。
