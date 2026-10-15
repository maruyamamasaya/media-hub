# iPhone読み込み状態の表示
## Request
読み込み中にメーターや状態を表示し、何を待っているか分かるようにする。
## Investigation
全画面写真はラベルなしのスピナーだけ。通常画像は取得を共有し、メモリ／ディスクキャッシュを使用。暗号化画像はメモリ復号。動画はAVPlayer生成後の準備／待機／失敗の表示がなかった。
## Changes
通常画像の実処理に段階通知を追加し、同一取得の待機者へ配信。共通表示でスピナー・段階・待ち秒数・15秒後の案内を表示。暗号化画像は受信・復号／照合を表示。全画面とランダム閲覧の動画でAVPlayerの準備／受信待ち／失敗を表示。状態確認だけで追加のメディア通信や自動再生は行わない。
## Files Changed
ios/PhotoHub/CloudViewer.swift、ios/PhotoHub/SealedViewer.swift、ios/PhotoHubTests/IntegrationTests.swift、CURRENT.md、本記録。
## Validation
iOS 17.4 Simulatorビルド・統合14テスト成功。同一画像12要求で1回だけの取得を維持し全待機者への段階通知を確認。キャッシュ利用時に受信表示を出さないことを確認。文書fast・diff空白検証成功。
## Result
通常／暗号化の全画面・ランダム閲覧で待機理由を表示。表示は実処理段階と経過時間で、取得率の推測値は使わない。
## Remaining Issues
バイト単位の進捗率・残り時間は未実装。実機への更新、画面レイアウト、動画の実通信停滞・復旧時の操作確認は未実施。
