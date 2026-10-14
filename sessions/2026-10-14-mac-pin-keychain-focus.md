# Mac PIN入力画面とKeychainフォーカス
## Request
暗号化アップロード前のPIN入力画面が勝手に閉じ、入力できない問題を修正。
## Investigation
MacRootViewは非アクティブとアクティブ復帰の両方でrelockし、privacyID変更によりPINシートの親ビューを破棄していた。Keychainのシステム認証もフォーカスを移す。
## Changes
Keychain操作だけを開始・終了コールバックで追跡。認証終了直後の再アクティブ化を最大1秒待ち、別アプリに残っていれば再ロック。アクティブ通知単独では画面を再生成しない。PINの設定確認もメインスレッド外で実行。暗号鍵の読込・保存・送信前読込にも適用し、再ロック後は処理を中断。
## Files Changed
Sources/PhotoHubCore/HiddenPagePIN.swift、macos/MediaHubMac/Model.swift・Views.swift・SealedViews.swift、Tests/MediaHubMacTests/RuntimeTests.swift、docs/ENCRYPTED-UPLOAD.md、CURRENT.md。
## Validation
Swift全22件中21件成功・実AWS1件skip。最後の中断ガード追加後は回帰テスト1件成功。Mac .appとiOS Simulatorビルド成功、文書fastとdiff空白確認成功。制限環境のRuntime子プロセステストは失敗したが、ローカル通信を許可した再実行で成功。
## Result
更新版を起動し、実MacでPIN入力シート表示を確認。以降本人が画面を操作していたため追加の再起動は行わなかった。最後の中断ガードはビルド済みで次の起動から有効。
## Remaining Issues
本人による実PIN入力・Keychain認証の一連の動作完了は未確認。鍵やPINはテストのために変更していない。iPhone実機の更新は行っていない。
