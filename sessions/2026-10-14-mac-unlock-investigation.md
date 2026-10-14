# Mac解除失敗の切り分け
## Request
Macで設定した鍵を解除できない。
## Investigation
S3鍵保存確認とは解除成功は別。Macのエラーが入力形式・不一致を同じ表示にしていることを確認。本人PINは取得・照合していないため失敗原因は未確定。
## Changes
Mac APIで入力形式不正400と保存された鍵との不一致403を区別する案内を追加。5秒待機429と通信・設定エラーは既存の別表示を維持。アプリを再起動し解除画面を開いた。
## Files Changed
local-api/vault/folder_privacy.py、この記録。
## Validation
鍵関連ローカルテスト3件成功。再起動・解除画面表示を確認。鍵・AWS・メディアは変更していない。
## Result
本人による再入力後の具体的エラー確認待ち。
## Remaining Issues
実PIN解除未確認。原因を未確定のままPIN誤入力と断定しない。
