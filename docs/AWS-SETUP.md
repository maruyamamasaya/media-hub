# AWS設定とデプロイ手順

## 今の状態と承認対象
2026-10-14にユーザーがAWS/S3利用の再開とAWS操作を許可。東京の独立S3スタック `photo-hub-storage` を作成済み。バケット名は `photo-hub-storage-bucket-ajgsbh5jtcvp`。1 KiBの実AWS往復・SHA-256照合・テスト版削除に成功。MacにはAWS CLI v2を確認済み。`photo-hub`プロファイルのブラウザログイン完了。本番の認証は無効化しない。

有料リソース作成前に確認する構成: 東京の非公開S3 Standard×1、Cognito User Poolと公開クライアント×1、HTTP API×1、128MB ARM Lambda×1、保持7日のCloudWatchログ。常時サーバー・NAT・クラウドDB・独自ドメインなし。総量100GBで概算$3–5/月（転送・無料枠・写真増加で変動）、詳細は [DESIGN.md](DESIGN.md)。この構成と費用の承認後に下記デプロイを行う。

## 前提
AWSアカウント、東京での作成権限、AWS CLIとSAM CLIを準備する。CLI認証はAWS IAM Identity Center/短期認証を推奨。Macでは `aws login --profile photo-hub --region ap-northeast-1` でブラウザ認証を開始できる。以降のコマンドは `--profile photo-hub` を付ける。秘密鍵やパスワードをチャット・Gitに貼らない。

## S3接続の確認

バケット作成後、まず読み取り検証を実行する。

```sh
python3 scripts/check-s3.py --profile photo-hub --bucket YOUR_BUCKET
python3 scripts/check-s3.py --profile photo-hub --bucket YOUR_BUCKET --write-test
```

後者は専用のランダムキーへ1 KiBだけ送信し、HEADのサイズ・SHA-256と取得バイト列を確認してテストオブジェクトを削除する。バージョニング有効時は作成した版だけを削除する。ライブラリ原本には触れない。Public Access Blockの4項目が無効なら書き込みを停止する。この確認だけではIAM・バケットポリシー全体の監査やアプリ接続の完了とはしない。SHA-256と条件付きPUTは[AWS公式仕様](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-object.html)を使用。

既存Web/PC素材のリモート転送はPC内の模擬保存のまま。別機能として[Mac手動フォルダアップローダー](MANUAL-FOLDER-UPLOAD.md)を追加済み。実AWS送信検証・iOS読取・既存ライブラリ統合・容量解放は次工程。この接続検証ツールは転送先を変更しない。

## 1. 認証だけ作成
まずテンプレートを検証し、承認されたAWSアカウントへデプロイする。DomainPrefixは世界で一意のCognitoドメイン用文字列へ置き換える。

```sh
aws cloudformation validate-template --template-body file://infrastructure/auth.yaml --region ap-northeast-1
aws cloudformation deploy --template-file infrastructure/auth.yaml --stack-name photo-hub-auth --parameter-overrides DomainPrefix=YOUR_UNIQUE_PREFIX --region ap-northeast-1
aws cloudformation describe-stacks --stack-name photo-hub-auth --region ap-northeast-1 --query 'Stacks[0].Outputs'
```

Cognitoコンソールで出力されたUser Poolに本人のメールアドレスのユーザーを一人だけ管理者作成する。Hosted UIの初回ログインで本人がパスワードを設定する。自己登録は禁止。ユーザー属性subを取得し、以下のOwnerSubへ設定する。Cognitoアカウントを作り直すとsubが変わるため、機種変更では同じアカウントを使う。

## 2. 非公開ストレージとAPIを作成
`infrastructure/service.yaml`はSAMテンプレート。UserPoolId、ClientId、OwnerSubは前段階の値（秘密ではない）。

```sh
sam validate --lint --template-file infrastructure/service.yaml --region ap-northeast-1
sam build --template-file infrastructure/service.yaml
sam deploy --guided --region ap-northeast-1
```

guidedでstack名photo-hub-service、3パラメータ、IAM作成権限を確認する。確認プロンプトは本番認証を無効化するものではない。初回デプロイ後は出力API/BucketNameを記録する。LambdaはAWSランタイムのboto3を使用するため、実環境でSDKのIfNoneMatch対応も確認する。

## 3. アプリに設定
開発用データからの自動移行は未実装。空のライブラリから開始する。
設定で開発用ローカル保存をオフにし、API URL・Cognito domain（末尾/なし）・Client ID・本人subを入力。本人ログインを実行。Cognito callbackは `photohub://callback`、公開client secretは作らない。

## 4. 本番検証
- AuthorizationなしのPOST /objectsが拒否される。
- 本人以外のJWTが403、範囲外キーが400になる。
- S3の匿名アクセスが拒否され、Public Access Blockの4項目が有効。
- HEIC原本・JPEG派生のSHA256とサイズをHEADで確認する。
- ログにJWTや署名URLが残らない。
- 削除予約、6分後の再試行、JSONを使った新規インストール復元を確認する。

## コスト管理と後片付け
AWS Budgetsで予算通知（例$5/月）を設定する。通知は課金の自動停止ではない。保存量・転送量を実測して見積もりを更新する。バケット・User PoolはRetain指定のため、stack削除でも残る。写真の永続削除やリソース破棄は別途明示的に確認して行う。古い正常JSONとtombstoneは自動削除しない。

## Web・PC用S3スタック

`infrastructure/storage.yaml` はS3だけを作成するCloudFormationテンプレート。既存iOS用 `service.yaml` のバケットとは別で、自動移行・相互接続はない。非公開、AES256暗号化、TLS必須、バージョニング有効、未完了マルチパートを7日で破棄する。原本や旧版の自動削除・Glacier移行は設定しない。旧版も保存容量として課金される。stack削除時はバケットを保持する。

```sh
aws cloudformation validate-template --template-body file://infrastructure/storage.yaml --profile photo-hub --region ap-northeast-1
aws cloudformation deploy --template-file infrastructure/storage.yaml --stack-name photo-hub-storage --profile photo-hub --region ap-northeast-1
aws cloudformation describe-stacks --stack-name photo-hub-storage --profile photo-hub --region ap-northeast-1 --query 'Stacks[0].Outputs'
```

AWS認証は端末のAWS CLIが管理する。ブラウザ画面やElectron rendererへ秘密鍵を渡さない。アプリ接続時にはバケット・キー範囲に限定した権限を整備する。
