# 0014: Mac専用SwiftUIへ移行
Date: 2026-10-14
Status: accepted

## Context
本人がSwiftUI版を希望し、Windowsからは基本アクセスしないためWindows対応終了を許可。現在はMac手動送信とiPhone閲覧が主用途。
## Decision
Macの通常画面をSwiftUIに移行し、Windowsデスクトップ対応を終了する。既存Pythonの送信・照合・動画作成・フォルダ鍵処理を維持し、S3原本・iPhone閲覧専用の方針を継承。判断0007を置き換える。
## Reason
Mac標準の画面・ファイル選択を使い、WindowsとのUI共有を目的としたElectron実行環境を通常起動から外す。検証済みの原本保全処理の書き直しを避ける。
## Alternatives
Electron継続と全処理のSwift化。前者は本人の希望と異なり、後者は送信・照合・ffmpeg管理の再検証を伴うため今回採用しない。
## Consequences
SwiftUIとPythonの境界・子プロセス停止・認証管理が必要。既存作業領域を継続利用し原本を削除しない。Python同梱・署名配布と性能実測は残る。詳細は [Mac SwiftUI](../docs/MAC-SWIFTUI.md)。
