# 画面保持・小画像キャッシュ・検索と共有お気に入り
## Request
画面保持→Macキャッシュ→検索／並び替え→Mac・iPhone共有お気に入りの順で実装し、テストは最後にまとめる。
## Investigation
Macは非アクティブ時に全モデルと画面識別を破棄していた。小画像は毎回S3取得。共有お気に入り用の書込APIはなかった。既存の本人認証・PIN・暗号化領域・ごみ箱と配備構成、既存iPhone署名を確認。
## Changes
通常画面の識別と一覧・履歴を維持。秘密領域だけ再ロックし、保護された子孫・検索／進行表示・閲覧／確認画面は除去。通常小画像は毎回認可・SHA確認後に256MiBキャッシュを使い、設定に使用量／削除を追加。名前検索と名前／逆順／容量順を追加。フォルダ・写真・動画・PDFに☆とお気に入り一覧を追加。暗号化素材は解除・復号後の専用入口で表示。共有状態は名前を含まない識別子だけを1キーへ保存し、ETag比較更新と最大3回再試行で別対象の同時更新を保持。
## Files Changed
MacのModel・Views・Gallery・SealedViewsと新規Favorites／LibraryControls、iPhoneのCloudViewer・SealedViewer・新規Favoritesとプロジェクト登録、共有LibraryBrowse／SharedFavorites、契約／生成型／生成器、backend favorites／readerとIAM・ルート、ローカルAPIのcache／shared_favoritesとメディア処理、関連テストと仕様・判断・運用・現在地。
## Validation
実装後にまとめて検証。ローカルAPI212件、backend48件、Swift42件（実AWS専用1件skip）、iOS Simulator統合19件成功。Mac/helper・iOS Simulator・実機ビルド成功。契約生成一致、文書full、YAML構文、diff空白を確認。初回fixtureのlocalhost制限を修正。追加確認でCLI条件付き書込を再試行可能な競合へ分類し、秘密の進行表示除去・キャッシュ障害時の閲覧継続も確認。

本番は配備中ZIPを退避してreader／favoritesだけを差し替え、CloudFormation変更セットで既存Api・Function・ReaderRoleの置換なし／お気に入り2ルートのLambda権限だけ追加と確認後に反映。CodeSha256一致、本人なし401・別本人403・不正要求400、HTTP未認証401を確認。初回未作成キーの読取は狭いList権限では502となったため、存在しない共有保存先を条件付きで空初期化し再試験。合成の空フォルダでiPhoneAPI追加→Mac bridge取得・解除→iPhoneAPI解除確認に成功。合成カタログは作成時のVersionIdだけ除去し残存なし。本人の素材・鍵・既存お気に入りは操作していない。

Macは送信中・予約中がないことを確認して更新版へ起動。実画面で検索・並び替え、キャッシュ設定、☆とお気に入り入口を確認。通常画面で検索を入力し別アプリ切替後も値が維持されることを確認し、検証文字は除去。Vesperaは既存ワイルドカードプロファイルと正確なアプリID・Keychain権限を照合し、内包ライブラリとアプリを署名検証して上書き更新。初回の署名照合停止後の未署名installは拒否され、署名修正後はinstall／launch成功、後続プロセス42245の存在を確認。
## Result
AWS・Mac・iPhoneへ反映済み。端末共有の往復を合成データで確認。元ファイル・S3実素材と失敗履歴は保持。使い方と制限はdocs/SHARED-FAVORITES.md。
## Remaining Issues
本人による実機の☆操作・PIN解除後の見た目と実素材での体感速度は未確認。共有は更新時でプッシュ／オフライン編集なし。Macキャッシュは通常小画像だけ。iPhone暗号化トップ一覧の検索、全階層索引、撮影日順、iPhoneごみ箱操作と暗号化ごみ箱は対象外。追加の速度実測は別課題。
