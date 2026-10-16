# コード探索の入口

| Feature | Primary paths | Search keywords / Key entry points | Related tests |
| --- | --- | --- | --- |
| PDF送信・閲覧 | `Sources/PhotoHubCore/PDFReader.swift`, `local-api/vault/pdf_preview.py`, `macos/MediaHubCrypto/main.swift` | `MediaPDFReader`, `pdfData`, `render_pdf`, `--pdf-thumbnail` | `test_pdf_upload.py`, `PDFTests.swift`, iOS `testPDFDownloadIntegrityRelockAndMemoryDecryption` |
| マイショート・動画 | `web/src/MyShort.tsx`, `local-api/vault/service.py`, `ios/PhotoHub/Views.swift`, `PhotoImporter.swift`, `LibraryModel.swift` | `MyShort`, `session_rank`, `video_preview`, `MyShortView`, `ShortVideo`, `videoDerivatives`, `loadPlayback` | `local-api/tests/test_my_short.py`, `desktop/short-smoke.cjs`, `IntegrationTests`（iOS未実行） |
| Web画面 | `web/src/App.tsx`, `AssetDetail.tsx`, `Modal.tsx`, `api.ts` | `App`, `upload`, `retryImports`, `AssetDetail`, `fileUrl` | Web build、ブラウザ一連操作 |
| 容量と費用・通信集計 | `local-api/vault/usage.py`, `backend/usage_report.py`, `Sources/PhotoHubCore/UsageDashboard.swift`, `UsageActivity.swift`, `macos/MediaHubMac/UsageScreen.swift`, `ios/PhotoHub/CloudViewer.swift` | `Usage`, `UsageNetworkObserver`, `PhoneUsageScreen`, `/usage` | `local-api/tests/test_usage.py`, `backend/tests/test_usage.py`, `Tests/PhotoHubCoreTests/UsageTests.swift` |
| 共有お気に入り・検索・Mac小画像キャッシュ | `backend/favorites.py`, `local-api/vault/shared_favorites.py`, `thumbnail_cache.py`, `Sources/PhotoHubCore/SharedFavorites.swift`, `LibraryBrowse.swift`, Mac/iPhone `Favorites.swift` | `FavoriteReference`, `toggleFavorite`, `ThumbnailCache`, `LibraryOrder` | `test_favorites.py`, `test_shared_favorites.py`, `test_thumbnail_cache.py`, `LibraryStateTests`, iOS `testFavoritesShareBetweenDevicesAndFailedWriteDoesNotChangeStar` |
| Mac SwiftUI | `macos/MediaHubMac/App.swift`, `Runtime.swift`, `Model.swift`, `Views.swift`, `Gallery.swift` | `MacRuntime`, `MacModel`, `MediaHubMacApp`, `relock`, `SquareTile`, `MediaGallery` | `Tests/MediaHubMacTests/RuntimeTests.swift`, `scripts/verify-desktop.sh` |
| Macアプリアイコン | `macos/Assets/AppIcon.png`, `AppIcon.icns`, `scripts/build-mac-icon.sh`, `build-mac-app.sh` | `CFBundleIconFile`, `iconutil` | ICNSサイズ・透過・同梱照合、署名、Finder実表示 |
| 旧Electron試作（Windows対応終了） | `desktop/main.cjs`, `preload.cjs`, `api-process.cjs`, `platform.cjs`, `local-api/desktop_run.py` | `startApi`, `pythonExecutable`, `menuTemplate`, `activate`, `desktop_token`, `watch_parent` | `desktop/api-process.test.cjs`, `platform.test.cjs`, `local-api/tests/test_desktop.py`, `scripts/verify-desktop.ps1` / `verify-desktop.sh` |
| ローカル素材API | `local-api/vault/app.py`, `service.py`, `repository.py`, `storage.py` | `create_app`, `Vault`, `process_item`, `recover`, `list_assets`, `require_revision` | `local-api/tests/test_vault.py` |
| 原本の所在・ローカル参照 | `local-api/vault/service.py`, `repository.py`, `web/src/App.tsx`, `AssetDetail.tsx`, `scripts/create-local-storage-demo.py` | `storageLocation`, `originalOwnership`, `sync_directory`, `storage_roots`, `transfer_original`, `referenceKey` | `test_existing_original_migrates_*`, `test_local_directory_reference_*` |
| 通常・アーカイブ | `web/src/ArchiveDialog.tsx`, `AssetDetail.tsx`, `local-api/vault/service.py`, `repository.py` | `archivedAt`, `bulk_archive`, `archive_collection`, `collection_archive_snapshot` | `test_archive_*`, `test_bulk_archive_*`, `test_collection_archive_*`, `test_v2_archive_migration_*` |
| 共通契約・iOS準備 | `contracts/asset.schema.json`, `scripts/generate-contracts.py`, `Sources/AssetLibraryContract/` | `--check`, `Asset`, `AssetFile`, `AssetLibraryAPIClient` | API契約検証、`AssetLibraryContractTests`（Swift未実行） |
| Web起動・検証 | `scripts/setup-web.ps1`, `start-web.ps1`, `verify-web.ps1`, `benchmark-library.py` | `127.0.0.1:8765`, `.local`, `TestClient` | Web verify、1,000件API測定 |
| アプリ入口・画面 | `ios/PhotoHub/PhotoHubApp.swift`, `Views.swift` | `PhotoHubApp`, `RootView`, `PhotoGrid`, `PhotoDetail`, `SettingsView` | シミュレータ手動、実機チェックリスト |
| 原本取り込み・派生 | `ios/PhotoHub/PhotoImporter.swift` | `importAsset`, `PHAssetResource`, `derivatives` | `IntegrationTests`、実写真手動 |
| iOSフォルダ・iCloud Drive参照 | `ios/PhotoHub/FolderSync.swift`, `LibraryModel.swift`, `Views.swift`, `Sources/PhotoHubCore/Models.swift` | `LibraryFolder`, `FolderSync`, `registerFolder`, `syncFolder`, `folderSource`, `FolderSettingsView` | `testFolderSyncRenameChangeMissingReconnectionAndSafeDeletion`, `testLegacyPhotoDecodingAndFolderReferencePersistence` |
| 写真モデル・SQLite | `Sources/PhotoHubCore/Models.swift`, `Repository.swift` | `Photo`, `UploadState`, `photos`, `albums`, `memberships`, `recoverInterruptedUploads` | `Tests/PhotoHubCoreTests/CoreTests.swift` |
| アップロードと再試行 | `Sources/PhotoHubCore/PhotoTransfer.swift`, `ios/PhotoHub/LibraryModel.swift` | `PhotoTransfer.upload`, `uploadPending`, `head`, `checksum` | `testPartialUploadThenRetryKeepsStableID`, `testFailedUploadPreservesPendingOriginalAndRecovers` |
| 本人認証・S3通信 | `ios/PhotoHub/Cloud.swift` | `Authentication`, `ASWebAuthenticationSession`, `S3ObjectStore`, `token`, `/objects` | 実AWS結合は未実施 |
| 署名API | `backend/app.py` | `handler`, `validate_key`, `OWNER_SUB`, `BUCKET`, `tombstone` | `backend/tests/test_api.py` |
| ローカル保存・キャッシュ | `Sources/PhotoHubCore/ObjectStore.swift`, `LibraryModel.swift` | `LocalObjectStore`, `DevelopmentObjects`, `DiskCache`, `trim`, `image` | `CoreTests`, `IntegrationTests` |
| 整理・削除・原本保存 | `LibraryModel.swift`, `Views.swift` | `toggleMembership`, `setFavorite`, `requestDelete`, `finishDelete`, `saveOriginal` | `IntegrationTests`, `CoreTests` |
| JSONバックアップ・復元 | `Models.swift`, `Repository.swift`, `LibraryModel.swift` | `Backup.validate`, `snapshot`, `restore`, `schemaVersion`, `latest.json` | `CoreTests`, `IntegrationTests` |
| フォルダ別パスワード・非表示 | `backend/folder_security.py`, `local-api/vault/folder_privacy.py`, `web/src/CloudFolders.tsx`, `ios/PhotoHub/CloudViewer.swift` | `visible`, `grants`, `folder-unlock`, `relock`, `revision` | `backend/tests/test_folder_security.py`, `test_reader.py`, `local-api/tests/test_folder_privacy.py` |
| iPhoneページ送り・拡大操作 | `ios/PhotoHub/MediaPager.swift`, `CloudViewer.swift`, `SealedViewer.swift` | `NativeMediaPager`, `ReaderMediaPage`, `PhoneZoomableImage`, `PhoneSealedImageSession` | iOS `testNativePagerCommitsOnlyCompletedTransitionsAndKeepsCurrentPageOnCancellation`, `testNativePagerStartsAtSelectedMediaAndZoomOnlyEnablesImagePanWhenEnlarged` |
| iPhone横断一覧・ランダム閲覧 | `ios/PhotoHub/CloudViewer.swift` | `ReaderOverview`, `ReaderEntry`, `ReaderSwipeScreen`, `ReaderOverviewMode` | `testOverviewSeparatesMediaAndKeepsIdentityAcrossFolders` |
| 管理情報16MiB・分割取得 | `backend/catalog_limits.py`, `reader.py`, `Sources/PhotoHubCore/CatalogTransfer.swift`, `ios/PhotoHub/CloudViewer.swift` | `CatalogLimits`, `CatalogDownload`, `catalogOffset`, `fetchCatalog` | `test_catalog_preflight.py`, `test_reader.py`, `CatalogTransferTests.swift`, iOS `testSixteenMiBCatalogDownloadAndCorruptionRejection` |
| iPhone閲覧・本人GET API | `ios/PhotoHub/CloudViewer.swift`, `backend/reader.py`, `infrastructure/reader.yaml` | `CloudViewerRoot`, `CloudViewerModel`, `/library`, `/catalogs` | `backend/tests/test_reader.py`、iOSビルド |
| S3ごみ箱・完全削除 | `local-api/vault/cloud_trash.py`, `backend/catalog_trash.py`, `macos/MediaHubMac/Views.swift` | `CloudTrash`, `CloudTrashScreen`, `purge_versions`, `/folder-library/trash` | `local-api/tests/test_cloud_trash.py`, `backend/tests/test_reader.py` |
| S3フォルダ閲覧 | `web/src/CloudFolders.tsx`, `local-api/vault/folder_upload.py` | `library`, `media`, `/folder-library` | `CloudLibraryTests` |
| 独立した暗号化送信・閲覧 | `local-api/vault/encrypted_upload.py`, `Sources/PhotoHubCore/SealedMedia.swift`, `SealedStreaming.swift`, `macos/MediaHubMac/SealedViews.swift`, `ios/PhotoHub/SealedViewer.swift`, `backend/encrypted_reader.py` | `EncryptedUploads`, `RecoveryFile`, `MediaSecretStore`, `SealedRangeReader`, `SealedPlayerLoader`, `/encrypted-library` | `test_encrypted_upload.py`, `test_encrypted_reader.py`, `SealedMediaTests` |
| 非公開S3サムネイル・一時閲覧 | `local-api/vault/folder_upload.py`, `scripts/publish-folder-thumbnails.py`, `macos/MediaHubMac/Gallery.swift` | `ensure_thumbnail`, `publish_thumbnails`, `release_media`, `purge_legacy_view_cache` | `CloudLibraryTests`、`ReaderTests` |
| 内容重複の送信除外 | `local-api/vault/upload_duplicates.py`, `macos/MediaHubCrypto/main.swift` | `prepare`, `duplicateCount`, `noCatalog`, `decrypt_catalog` | `local-api/tests/test_upload_duplicates.py` |
| アップロード改善・分割再開 | `local-api/vault/folder_upload.py`, `s3_pooled.py`, `multipart_upload.py`, `encrypted_upload.py`, `macos/MediaHubMac/Views.swift`, `UploadBatch.swift` | `start_queue`, `begin_scan`, `snapshot`, `parallel_items`, `put_resumable`, `put_verified`, `prepareUploads`, `dropDestination` | `local-api/tests/test_s3_pooled.py`, `test_upload_improvements.py`, `Tests/MediaHubMacTests/UploadBatchTests.swift` |
| Mac手動フォルダアップロード | `local-api/vault/folder_upload.py`, `web/src/FolderUploader.tsx` | `FolderUploads`, `/folder-uploads`, `scan`, `start`, `pause` | `local-api/tests/test_folder_upload.py` |
| Mac軽量動画の手動作成 | `web/src/LightVideoMaker.tsx`, `local-api/vault/light_video.py`, `desktop/preload.cjs` | `LightVideos`, `prepare_upload`, `chooseVideo`, `/light-videos` | `local-api/tests/test_light_video.py` |
| 動画容量・転送比較 | `scripts/audit-video-storage.py`, `docs/VIDEO-DELIVERY.md` | `survey`, `estimate`, `ffprobe` | `scripts/tests/test_video_audit.py` |
| S3実接続確認 | `scripts/check-s3.py`, `infrastructure/storage.yaml` | `check`, `photo-hub-storage`, `--write-test` | `scripts/tests/test_check_s3.py`、実AWS 1 KiB往復 |
| デプロイ | `infrastructure/auth.yaml`, `service.yaml` | `OwnerJWT`, `OwnerSub`, `BlockPublicAccess`, `BucketPolicy` | YAML構文、SAM/実AWSは未実施 |
| 検証入口 | `scripts/verify.sh`, `verify.py` | `--fast`, `REQUIRED`, `local_links` | 文書verifyの異常系確認 |

パスの短縮表記は表内の同じ領域にあるファイルを指す。領域固有のルールは `ios/AGENTS.md`、`backend/AGENTS.md` を変更前に読む。

## 検索の使い分け
| 分かっていること | 手段 |
| --- | --- |
| 概念だけ | 利用可能ならsemantic/repository search。なければ本書から語彙を選ぶ |
| 関数・クラス・コンポーネント名 | symbol / exact search |
| APIパス・テーブル名・環境変数・エラー文字列 | `rg -n -F '文字列' 対象ディレクトリ` |
| 呼び出し元と変更影響 | references search、名前の検索、関連テスト検索 |
| TODO / FIXME | `rg -n 'TODO|FIXME' Sources ios backend` |

`rg --files`で配置を確認し、検索範囲を絞る。追跡済みコードは `git grep -n '語句'` でも検索できるが、未追跡ファイルは `rg` を使う。入口 → 処理 → データアクセス → 外部依存 → テストの順に必要な部分だけ読む。

semantic indexやlanguage serverの設定は存在しない。将来利用可能になった場合も、検索結果の定義・参照を実コードで確認する。
