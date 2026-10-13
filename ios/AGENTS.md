# iOS領域
ルートAGENTS.mdに加えて適用する。SwiftUI / PhotoKit / SQLiteを使用する。
- 画像原本はPHAssetResource `.photo`、動画原本は `.video` を無加工で書き出す。派生画像・再生用MP4と原本を混同しない。
- 写真ライブラリの削除APIを使わない。
- UIとRepository更新はMainActor。画像変換はバックグラウンドで行う。
- pending原本はキャッシュ削除対象にしない。
- 本番クラウドはログイン必須。LocalObjectStoreは明示的な開発専用モード。
- ビルドと実機の検証方法はTESTING.md、導入はOPERATIONS.md。
