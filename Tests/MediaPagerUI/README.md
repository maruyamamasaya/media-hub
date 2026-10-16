# ページ送りの実タッチ回帰テスト

実行ごとに本体の [MediaPager.swift](../../ios/PhotoHub/MediaPager.swift) を一時領域へコピーして使い、合成画像だけで横／縦送り、短いドラッグの取消、端の抵抗、ピンチ中のページ送り禁止を検証する。ネット接続・本人素材・認証・AWSは使わない。生成プロジェクトとビルドは一時領域へ置く。

XcodeGenとiOS Simulatorが必要。リポジトリルートから実行し、destinationのIDを利用可能なiPhoneへ置き換える。

```sh
sh scripts/verify-media-pager.sh SIMULATOR_ID
```

`personal.mediahub.pager-preview` は検証用の別アプリ。本体アプリのデータ・Keychainを共有しない。結果はスクリプトが表示する一時領域の `build/Logs/Test/` に記録される。人が感じる実機の滑らかさやフレーム落ちの計測を代替するものではない。

ピンチはアプリ全体ではなく `media-image-zoom` の画像領域へ送る。全画面の端から始めると上部操作やステータスバーへ指がかかり、縮小を正しく再現できない。XCTestの倍率・速度の合成は近似なので、終了時の実際の等倍状態を確認する。[AppleのAPI仕様](https://developer.apple.com/documentation/xcuiautomation/xcuielement/pinch(withscale:velocity:))。並列シミュレータ実行は無効化している。
