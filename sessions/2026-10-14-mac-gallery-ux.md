# Macタイル一覧と前後ファイル移動
## Request
Mac UI/UXを改善。正方形タイルを維持し、一覧情報は少なく、容量を隠してタイトルを小さく。クリック後に左右で次のファイルへ進める。
## Investigation
Mac SwiftUI画面、同じフォルダのファイル順、認証・再ロック、原本取得、一時ファイルとAVPlayerの終了を確認。既存thumbnail APIは未生成の小画像に404を返す。
## Changes
フォルダとメディアをLazyVGridの正方形タイルへ変更。下部10pt・1行タイトルのみで容量・件数を省略。クリックでシートを開き、左右ボタン／矢印キーで同じフォルダ内の前後へ移動。先頭・末尾で停止、Escで同じ一覧へ復帰。切替で旧MediaScreenを破棄し動画・一時ファイルを回収。
閲覧済みの照合済み原本キャッシュだけから320px小画像を生成。原本の一覧一括取得を増やさず、透過を保持し小画像キャッシュを64MiBまでに制限。ビューア終了後にタイル小画像を更新。
画面実機検証でサムネイルへのEnvironmentObject伝播不足によるクラッシュを確認し、アプリのルートで共有状態を提供するよう修正。
## Files Changed
macos/MediaHubMac/Gallery.swift、Views.swift、App.swift、local-api/vault/folder_upload.py、local-api/tests/test_folder_upload.py、CURRENT、CODEMAP、TESTING、docs/MAC-SWIFTUI、作業記録。
## Validation
SwiftUIビルドと開発用.app生成成功。Swift全15テスト、ローカルAPI全67テスト成功。小画像の非取得・透過保持・原本不変・破損キャッシュ拒否の追加2テスト成功。
Mac実機で保存済み9画像を閲覧し、正方形タイル・小タイトル・容量なし・クリック・左右ボタン・←→キー・連続移動・1/9と9/9の境界・Escで一覧へ戻る・画像小タイルの更新を確認。文書・契約・差分検証成功。
## Result
Mac版の情報を抑えたタイル一覧と連続閲覧を実装。S3送信・原本変更・削除は行わず、閲覧とキャッシュ生成のみ。
## Remaining Issues
未閲覧で小画像がない画像と動画は一覧でアイコン表示。動画を含む実機の連続移動、大量素材、VoiceOverは未確認。Python同梱・署名配布、原本100MiBの既存閲覧上限は今回変更なし。iOS画面・AWS構成は変更せず、今回iOSビルド/統合テストは再実行していない。
