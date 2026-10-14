# iPhoneとMacの抽象アイコン統一
## Request
iPhone版も、承認済みのMac版と同じアイコンにしたい。
## Investigation
iOS AppIconの1024px universal設定とビルド参照、iOS領域ルール、実機更新手順を確認。接続済みの既存端末Vesperaと前回署名資産を照合。
## Changes
Macの承認済みPNGをそのまま使い、不透明RGB・1024pxへ書き出してiOS AppIconを更新。透過部分のみ深緑に合成し図案は変更しない。render-app-icon.swiftを共有原稿のiOS書き出し用に変更。既存署名・provisioning・Keychain entitlementsを保持した作業コピーをVesperaへ更新インストール。アンインストール・データ初期化・AWS更新なし。
## Files Changed
ios/PhotoHub/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png、scripts/render-app-icon.swift、macos/Assets/AppIcon-prompt.txt、docs/MAC-SWIFTUI.md、CURRENT.md、作業記録。
## Validation
1024×1024 RGB・alphaなしと画像を確認。署名なしiphoneosビルド成功、コンパイル済みAppIcon参照とPNG同梱を確認。既存profileの期限・端末対応・証明書・Keychain権限を照合。内包dylibとアプリ全体の署名検証成功。Vesperaへの更新install・launch成功、後続process一覧で動作継続を確認。Simulatorの既存統合5テスト成功。文書verify・差分チェック成功。
## Result
iPhone版をMacと同じ抽象アイコンへ更新し、実機への反映と起動を完了。原稿は共有し、新しい画像生成は行わない。
## Remaining Issues
実iPhoneのホーム画面の目視は本人確認待ち。今回アプリの機能ロジックとAWS設定は変更していない。
