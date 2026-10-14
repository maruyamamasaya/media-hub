# 現在の構成

## System Overview / Technology Stack
現行Mac版は `macos/MediaHubMac/` のSwiftUI。MacRuntimeが既存Python APIを認証付きloopback子プロセスとして管理し、Swift DTOを介して送信・閲覧・軽量動画・鍵を操作する。作業領域は既存の `.local/desktop-library` を継承。Windows対応は終了。Electronの `desktop/` は旧試作の保全用。[Mac SwiftUI](docs/MAC-SWIFTUI.md)。

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

Macの通常／暗号化送信は非同期確認 → 確認済みフォルダ予約 → 最大2件並列（大容量は単独） → 条件付きPUT／再開可能multipart → 管理情報確定。暗号文だけの再開用保持と照合は[アップロード改善](docs/UPLOAD-IMPROVEMENTS.md)。
暗号化用は独立したEncryptedUploads → 同梱MediaHubCrypto（CryptoKit・鍵はstdinのみ） → encrypted-objects／encrypted-catalogsの非公開S3 → 本人限定GET URL → 共通SealedRangeReader／AVAssetResourceLoaderで必要断片をメモリ復号。鍵はKeychain、復旧ファイルはPBKDF2＋AES-GCM。[暗号化構成](docs/ENCRYPTED-UPLOAD.md)。

現行S3閲覧: Macの確認済み入力 → 原本と最大50KBのサムネイルを非公開S3へ → カタログ登録 → Macの認証付きローカルAPI／iPhoneの本人・フォルダ認可＋5分署名GET → 表示メモリ。Macの転送用ファイルは応答完了、原本表示用ファイルは閲覧終了で破棄し、長期閲覧キャッシュは作成しない。[小画像保管方針](decisions/0015-private-thumbnails-no-durable-cache.md)。

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

iOS通常閲覧はCloudViewerModel → メモリ／ReaderImageDiskStore専用actorの最大1GBキャッシュ → 未取得サムネイルの最大60件一括署名 → 非公開S3。署名要求と同一画像の同時取得を共有し、ディスク／原本照合をUIから分離する。暗号化内容はメモリのみ。[キャッシュと一括署名](docs/S3-READER.md)。

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

iOSのフォルダ参照はFile Importerでユーザーが選んだディレクトリへのsecurity-scoped bookmarkをApplication Support/PhotoHub/folders.jsonに保存する。SQLiteは端末内に置き、Photoの任意folderSourceに固定Root UUIDと相対パスを保持。FolderSyncがNSFileCoordinatorによる原本読み取りとSHA-256照合を行い、派生だけ端末のキャッシュへ保存する。AWS ObjectStore経路とは独立。仕様・制限は [iOSフォルダ同期](docs/IOS-FOLDER-SYNC.md)。

既存iOS/AWS:
Cognito Hosted UI Code + PKCE S256。refresh tokenはKeychain、署名URLは保存しない。API Gateway JWT authorizer + LambdaのOwnerSubチェック。開発用ローカル保存は独立したテスト用経路。

## External Services / Deployment
東京S3 Standard（原本・派生・JSON）、Cognito、Lambda、HTTP API、CloudWatch。クラウドDBなし。Web/PC接続準備用に独立した非公開S3スタックphoto-hub-storageを作成済み（storage.yaml）。アプリとの接続と既存iOS用認証/APIのデプロイは未実施。設定は [OPERATIONS.md](OPERATIONS.md)。

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

Mac手動S3アップロードは `vault/folder_upload.py` とWebのFolderUploader。選択・確認・明示開始、コピー送信、条件付きPUTとSHA-256 HEAD照合、全原本照合後に非公開のフォルダカタログJSONを確定。転送状態は独立した端末JSON、SQLite素材ライブラリは変更しない。監視・自動同期なし。詳細は [手動フォルダアップロード](docs/MANUAL-FOLDER-UPLOAD.md)。

S3フォルダ閲覧はCloudFoldersと `/api/v1/folder-library`。最新の保存完了カタログをroot単位で選択し、既存SQLite素材とは独立して階層表示。ローカル原本の照合済みコピー／明示オープン時の固定S3版GETをファイルAPIで返す。原本は100MiB、キャッシュは500MiBで追加取得を停止する。

2026-10-14の新方針: 原本の正本はS3、Mac手動アップロード、iOS閲覧専用。通常UIはCloudApp／CloudViewerRoot。旧ローカルUIは実行しない。閲覧API reader.handlerはCognito JWT＋本人sub検証、GET URLのみ。IAMもS3 Get/Listと専用ログのみ。構成と承認範囲は [S3 Reader](docs/S3-READER.md)。

Macの手動軽量動画作成はLightVideoMaker→ループバックlight-videos API→ffprobe/ffmpeg。原本を読み、アプリデータ内の派生作業領域へ保存する。AWS通信は行わない。構成・保持と承認境界は [動画配信](docs/VIDEO-DELIVERY.md)。

フォルダロックは非公開S3の管理JSONをMacが条件付き更新し、本人閲覧LambdaとMac APIが同じPBKDF2・HMAC認可処理で未解除の階層を除外する。iPhoneは解除APIとGETのみで設定を書かない。詳細は [フォルダロック](docs/FOLDER-LOCK.md)。

## マイショートと動画
WebはMyShort→既存一覧APIのsort=random/seed→display File配信。安定したハッシュ順位を既存カーソルに結び付け、メタデータを20件ずつ取得する。動画は原本保管後、任意FFmpegでJPEG thumbnailとH.264/AAC MP4 displayを生成し、失敗を原本から独立して記録する。iOS旧PhotoはAVFoundationでポスターとplayback.mp4を生成し、開発用保存では追加キーを照合転送する。AWS動画転送は拒否する。DB/共通DTOの構造変更はない。[仕様と制限](docs/MY-SHORT.md)。

S3のごみ箱は各カタログのtrash記録で管理し、共通のcatalog_trashが通常一覧・取得URLを除外する。Mac管理APIがETag条件付き保存と照合後に正確な原本／小画像キーの全版を削除し、失敗時はdeleting記録を維持する。小さな管理履歴は保持する。[操作と制限](docs/S3-TRASH.md)。

費用集計はMacの手動S3全版一覧 → 集計JSON `media-hub/usage/latest.json` → 本人限定閲覧API → iPhone。保存量／保存費試算の履歴を共有し、通信記録は端末内の数値集計のみ。既存予算はアカウント全体として区別する。[計測範囲と操作](docs/USAGE-DASHBOARD.md)。
