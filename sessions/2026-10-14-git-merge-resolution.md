# 同期時のマージ競合解消
## Request
Macとorigin/mainの変更を保持して同期する。
## Investigation
8ファイルが競合。MacのS3/SwiftUI構成と旧ローカルUIのマイショート追加が並行していた。
## Changes
通常入口のCloudAppを維持し、旧UIのS3導線とマイショートを統合。iOSのフォルダ同期と動画ビューを併存。文書は現行方針を維持し追加仕様を記録。
## Files Changed
ARCHITECTURE.md、CURRENT.md、OPERATIONS.md、TESTING.md、contracts/README.md、ios/PhotoHub/Views.swift、web/src/App.tsx、web/src/styles.css。
## Validation
一時コピーでWeb型チェックとVite build、Swift構文parse、backend 24テスト、文書fast verify成功。local-api 70テスト中69成功、子プロセス起動テスト1件はJSON応答を受け取れず失敗。元ツリーへのgit apply --check成功。
## Result
競合解消パッチを作成。元リポジトリは未変更、マージコミットとpushは未実施。
## Remaining Issues
実Macで標準verify、iOS Build/Integrationと画面確認が必要。
