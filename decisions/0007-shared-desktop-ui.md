# 0007: Mac・WindowsでWeb UIを共有する構成案
Date: 2026-10-07
Status: superseded

2026-10-14に [0014: Mac専用SwiftUI](0014-native-mac-swiftui.md) で置き換え。

## Context
ユーザーは現UIを踏襲したMac・Windowsアプリの設計と開発のキャッチアップを希望。React WebとPython APIが存在し、デスクトップシェルは未実装。

## Decision
React UIとAPI契約を両OSで共有し、Electronシェル＋既存Python API子プロセスを第一候補とする。[設計と開発ゲート](../docs/DESKTOP-DESIGN.md)のD1試作後に採用を確定する。

## Reason
現在の素材UIと整理機能を引き継ぎ、Webの改善を同時に反映できる。OS固有の追加・保存・メニューを小さい境界へ集約できる。

## Alternatives
TauriはWebView差と配布管理を検証する代替候補。SwiftUIとWindows個別UIは二重実装が必要。設計時は依存追加なし。その後ユーザーのWindows開発開始指示によりElectron依存を追加して技術試作を開始。正式採用は実機操作・配布評価後に確定する。

## Consequences
Python同梱・子プロセス管理・ローカルAPI認証・署名が必要。配布容量とメモリを実測する。既存Webデータを自動移行せず、両OS間同期は別工程。Windowsでの成功だけでMac検証完了にしない。
