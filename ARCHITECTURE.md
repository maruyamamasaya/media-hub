# 現在の構成

## System Overview / Technology Stack
Mac・Windows開発用シェルは `desktop/` のElectron。mainが `local-api/desktop_run.py` を子プロセスで起動し、共有Webビルドを同一originで表示する。空きloopbackポート、起動トークン、OSライブラリロック、stdin切断による停止を利用。`platform.cjs`がPythonパスとOSメニューを分岐。Macは閉じる操作後もAPIを維持しactivateで再表示、Windowsは最終ウィンドウ終了でアプリも終了する。試作保存は `.local/desktop-library`。Mac実機と配布時のランタイム同梱は未検証・未対応。[起動・検証](docs/DESKTOP-OPERATIONS.md)。

ローカルWeb素材ライブラリはReact 19 / TypeScript / Vite 7、Python 3.12 / FastAPI / Pillow / 標準SQLite。127.0.0.1のAPIがWebビルドも配信する。新WebのDBと既存iOSのDBは独立し、同期は未接続。共通契約からWeb型・Swift DTOを生成する。

個人向けiOS写真管理。SwiftUI / PhotoKit / ImageIO / CryptoKit / OS標準SQLite3、iOS 17以上。追加のSwift依存なし。共有ロジックはSwift Package。開発用保存はアプリ内ファイル。本番向けPython Lambda / S3 / Cognito / HTTP APIのコードとテンプレートは存在するが未デプロイ。

## Directory Structure / Main Components
```text
photo-hub/
├─ Sources/PhotoHubCore/   モデル・SQLite・オブジェクト保存・転送
├─ Tests/                 共有ユニットテスト
├─ ios/PhotoHub/          SwiftUI・PhotoKit・認証・状態管理
├─ ios/PhotoHubTests/     iOS統合テスト
├─ ios/PhotoHub.xcodeproj/ 生成済みプロジェクト
├─ backend/              署名API・テスト
├─ infrastructure/       認証とサービスのテンプレート
├─ docs/                 設計・AWS導入・実機検証・段階別プロンプト
├─ decisions/            設計判断
├─ sessions/             作業結果
└─ scripts/              Fast/Full verify
```
主要シンボルと検索語は [CODEMAP.md](CODEMAP.md)。

追加配置: `web/`が素材UI、`local-api/vault/`がローカルAPI・サービス・DB・保存、`contracts/`が共通仕様、`Sources/AssetLibraryContract/`が生成Swift DTOと取得クライアント、`Tests/AssetLibraryContractTests/`がMacで実行する契約テスト。開発素材・DBはGit除外の `.local/`。

## Data Flow
Web: ファイル選択/テストフォルダ → ImportJob/Itemとstaging → 原本照合 → Asset/File登録 → 派生生成。Browser → API → SQLiteの検索/整理 → StorageのFile IDによる画像配信。派生失敗でも原本を保持する。削除はごみ箱から完全削除、deletingを起動時に再試行する。

以下は既存iOSの経路で、新Webの3ファイル必須条件ではない。
```text
Photos Picker → PhotoKit原本 → Pendingファイル + JPEG派生 → SQLite
                                   ↓
                             PhotoTransfer
                                   ↓
                LocalObjectStore / 本人JWT API → 非公開S3
                                   ↓
                    HEADサイズ・SHA256照合 → uploaded
SQLite → LazyVGrid / 詳細 → 派生キャッシュ → 必要時GET
SQLite → JSON正常版 + latestポインター → 空SQLiteへの復元
```

## API Structure
新Webは `/api/v1` のassets/imports/tags/collections/status。ファイルはAsset/File ID経由。更新はrevisionで409競合を検出。一覧は検索条件に結び付いたcursorでページ分割。正本は [共通契約](contracts/README.md)。

以下は既存AWS署名API。
POST `/objects`: head / put / get / delete。安定した本人キーだけを受け、URLは5分で失効。PUTはchecksum・サイズ・形式を署名、写真と正常JSONはIf-None-Matchで重複上書きを防ぐ。削除はS3 tombstoneで再署名を禁止し、6分後に既存署名の失効を待って完了する。

## Database
新Web: AssetRepository、schema version 7。assets/files、tags/asset_tags、collections/asset_collections、jobs/import_items。原本ハッシュの一意制約、外部キー、WAL、関連編集トランザクション。ライブラリは固定のlocal-library、ownerはローカル開発用。旧iOSからの移行は後工程。

既存iOS:
SQLite WAL + foreign_keys。`photos`はID・資産ID・SHA256・撮影日時・JSONメタデータBLOB（画像ではない）。`albums`と`memberships`で整理情報を持つ。状態・お気に入り・安定キーはメタデータに含む。復元は空DBだけ、検証後トランザクションで取り込む。スキーマはversion 1。

## Authentication
新Webはloopback限定でログインなし。Host/origin制限、別サイトからのアクセスとサイズ不明multipartを拒否する。本番モードは起動しない。Web本番認証は未実装。

既存iOS/AWS:
Cognito Hosted UI Code + PKCE S256。refresh tokenはKeychain、署名URLは保存しない。API Gateway JWT authorizer + LambdaのOwnerSubチェック。開発用ローカル保存は独立したテスト用経路。

## External Services / Deployment
東京S3 Standard（原本・派生・JSON）、Cognito、Lambda、HTTP API、CloudWatch。クラウドDBなし。実AWSは未作成。設定は [OPERATIONS.md](OPERATIONS.md)。

## Important Dependencies
標準Appleフレームワーク・SQLite・Python標準ライブラリ。LambdaはAWSランタイムboto3を使う。XcodeGenはプロジェクト再生成時のみ。verifyはPython、Swift、Ruby、Xcode。CI/CDとsemantic indexは未導入。

新Web設計は [素材ライブラリ設計](docs/ASSET-LIBRARY-DESIGN.md)、既存iOSの理由・費用・形式は [DESIGN.md](docs/DESIGN.md)、履歴はdecisionsとsessions。

## 一覧メタデータと一括操作
ローカルDB version 2はassets.originalExtensionを追加し、version 1の原本ファイル名から自動補完する。追加/撮影/更新日時とタイトルはassets、原本容量はfiles、タグ所属はasset_tagsをSQLで検索・整列する。拡張子と日時・タイトルに索引を持つ。DTOのAssetは従来互換を保つ。一括所属更新は全revision確認後に同一DBトランザクション、ZIPは原本を一時ファイルへまとめ応答後に削除。

## 通常とアーカイブ
DB version 3はassets.archivedAtと一覧用索引を追加し、既存素材は通常（null）へ移行する。Assetにも同項目を公開。物理ファイルは移動せず、状態の変更をDBの単一トランザクションで行う。選択操作はrevision、コレクション全体は確認時の全所属素材スナップショットのtokenで競合を検出する。WebはArchiveDialogで対象・影響を確認し、API結果の更新件数を表示する。S3保存クラス切り替え・非同期保管ジョブは未実装。仕様は[共通契約](contracts/README.md)、方向性は[設計判断](decisions/0006-normal-and-archive-storage.md)。

## 小さい画像と透過プレビュー
Web一覧では原本の縦横がともに128px以下の素材を拡大せず中央に表示し、寸法を添える。透過画像の派生はPNG、非透過はJPEG。既存JPEG派生は詳細の再生成で更新できる。小画像のWeb表示は対応する原本を使用し、旧派生でも透過を確認できる。詳細は全体・原寸・4倍とpixelated表示を切り替える。

原本の所在はローカルSQLite v6のstorageLocation、originalOwnershipで管理する。objects/local-originalsは通常ファイルを保存し、フォルダ登録では参照原本を複製しない。既存原本は開発用リモートとして分類するがPC内に保持する。詳細・将来の複数所在設計は [保管設計](docs/STORAGE-DESIGN.md)。

Windows試作は明示的な --web-library 起動により停止中のWebライブラリを開ける。既定は独立ライブラリ。手順は [デスクトップ運用](docs/DESKTOP-OPERATIONS.md)。

ローカルDB v6はstorage_roots・local_sourcesで外部フォルダ参照と固定ID／SHA-256照合、remote_originals・transfer_cleanupで模擬転送と整理再試行を保持。Electron preload.cjsは選択したフォルダパスだけを返すIPCを公開し、API認証情報は公開しない。

DB version 7はローカル素材のarchivedAtを解除（revision更新）する。アーカイブAPIはリモートのみ許可し、混在選択は全件拒否。コレクションの確認・更新対象もリモートのみ。ローカル転送・参照同期時は通常扱いへ戻す。原本・タグ・所属は保持する。

## マイショートと動画
WebはMyShort→既存一覧APIのsort=random/seed→display File配信。安定したハッシュ順位を既存カーソルに結び付け、メタデータを20件ずつ取得する。動画は原本保管後、任意FFmpegでJPEG thumbnailとH.264/AAC MP4 displayを生成し、失敗を原本から独立して記録する。iOS旧PhotoはAVFoundationでポスターとplayback.mp4を生成し、開発用保存では追加キーを照合転送する。AWS動画転送は拒否する。DB/共通DTOの構造変更はない。[仕様と制限](docs/MY-SHORT.md)。
