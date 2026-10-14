# 再ロック後の一覧再取得を修正
## Request
鍵未設定なのに解除画面へ案内されて解除できない。
## Investigation
誤って解除画面を開いていた。更新で既存フォルダが表示。再ロック中のbusyで再取得が省略され、pollのloaded状態で再試行しない経路を確認。
## Changes
再ロック時に再取得要求を保持し、正常に一覧を反映するまでpollで再取得する。
## Files Changed
macos/MediaHubMac/Model.swift、この記録。
## Validation
Macビルド・署名、RuntimeTests3件成功。再起動後に自動で既存フォルダ表示、鍵なし状態と6桁PINの設定画面を実UI確認。
## Result
設定画面を開いて本人へ引き継ぎ。PIN入力・設定は行っていない。
## Remaining Issues
本人による設定・iPhone解除確認。
