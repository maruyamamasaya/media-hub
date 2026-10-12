# フォルダ同期版の実機更新
## Request
フォルダ同期版をデプロイする。直前の会話に基づき既存iPhoneへの更新インストールとして実施。
## Investigation
接続端末Vespera（iPhone 17e）を前回と同じ端末識別情報で照合。既存ワイルドカードprofileの期限・端末対応・証明書一致を確認。
## Changes
最新ソースを実機向けにビルド。既存profileとidentityだけで作業コピーをオフライン署名し、personal.photohubを更新インストール。
## Files Changed
CURRENT.md、この作業記録。アプリコード・プロジェクト署名設定の変更なし。
## Validation
署名なしiphoneosビルド成功。初回install成功後、launchは端末ロックで失敗（Locked）。再試行では起動要求成功後にプロセスが終了。consoleでPhotoHub.debug.dylibの署名不足を確認し、同ライブラリと__preview.dylibを既存identityで署名してアプリを再署名。各ライブラリのcodesign --verify --strictとアプリ全体の--deep --strictを確認し、再install成功。launch成功後、後続のprocess一覧にPID 34688の存在を確認。
前ターンでSwift Package 12テスト、iOS統合5テスト成功済み。今回は実装変更がないため再実行なし。
## Result
Vesperaへの最新版の更新インストール・起動とプロセス存在を確認。アンインストール・データ初期化・署名資産の新規作成なし。
## Remaining Issues
最新画面の目視、実際のiCloud Driveフォルダ選択・同期は未確認。
