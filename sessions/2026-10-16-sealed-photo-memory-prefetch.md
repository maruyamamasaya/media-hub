# 暗号化写真のメモリ限定先読み
## Request
復号画像を端末ファイルへ保存せずに先読みし、表示待ちと通信・料金への影響を改善する。
## Investigation
従来はページ確定後に初めて原本を取得・復号していた。SealedHTTPはephemeral/no URLCache、RangeReaderはメモリのみであり、この境界を維持できる。
## Changes
PhoneSealedImageSessionで表示と先読みの取得／復号を共有。Wi-Fi／有線・非従量・省データ無効時に直後1枚、5MiB以下だけ。ヘッダー／タグ込みで解除中50MiBを予約し、取消／失敗でも返却しない。設定で停止可能。通常キャッシュとは分離。
現在／前／次の容量内だけを最大128MiB保持し、全体SHA照合と長辺4096px以下の表示用展開はバックグラウンドで実施。閉じる／背景／再ロック／鍵変更で取消・参照破棄し、遅延結果の復活を拒否。メモリ警告は現在画像を残して先読み停止。PDF／動画の先読みは追加しない。
## Files Changed
iOS SealedViewer.swift、CloudViewer.swift、IntegrationTests.swift、閲覧／暗号化仕様、ARCHITECTURE.md、CODEMAP.md、TESTING.md、CURRENT.md、判断0027。
## Validation
iOS統合27件・実タッチUI2件、Simulator／実機ビルド成功。合成AES-GCM復号・通信共有1回・隣ページの実描画と破棄・改ざん・権限失効と遅延結果・容量／回線条件を確認。文書full・diff空白確認成功。Vesperaへ既存設定を保持して上書き更新し、起動とプロセスを確認。
## Result
メモリのみの暗号化写真先読みを実装してVesperaへ反映。AWSの課金対象を公式資料で確認し、未閲覧分・再取得・解除回数による増加を仕様に明記。
## Remaining Issues
本人の実写真・実回線での待ち時間、NWPathMonitorの実回線切替、実請求との照合は未実施。50MiBは論理予約枠で月額請求の強制上限ではない。OS管理メモリの残留ゼロは保証しない。画面を開き直すと再取得する場合がある。
