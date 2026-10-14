# Asset Library API v1
正本はasset.schema.json。`python scripts/generate-contracts.py`でWeb型と独立したSwift DTOを生成し、`--check`でずれを検出する。文字列kind/role/stateは未知値でもデコードできる。日時はUTC ISO8601文字列、nullableはJSON null、サイズ・revisionは整数。既存PhotoHubCore.Photoと別モデル。

APIは `/api/v1`。GET /assetsはq、view（all/favorites/archive/trash）、archive（normal/archived/all）、kind、collection、sort（added/name/captured/updated/size/random）、order（asc/desc）、tag（複数指定・全タグ一致）、extension（複数指定・いずれか一致）、limit（1–100）、cursorを受けAssetPageを返す。cursorは検索条件に結び付け、条件が変われば破棄する。

POST /importsはmultipart files、GET /imports/{id}はImportJob、POST /imports/{id}/retryは保持済み失敗項目だけ再処理。POST /fixture-importsは設定済みテストフォルダを取り込む。GET /assets/{id}はAsset。PATCH /assets/{id}はrevisionとname/note/kind/favorite/tagIds/collectionIdsの任意変更を受ける。未知フィールドは拒否する。

POST /assets/{id}/trash、/restore、DELETE /assets/{id}はrevisionを受ける。DELETEはごみ箱内だけ。POST /assets/{id}/preview-retryは派生再生成。GET /assets/{id}/files/{fileId}/contentはファイル本体。`?download=true`はattachment。URLは一時的な配信情報で、データモデルへ保存しない。

GET/POST /tags、GET/POST /collections、PATCH/DELETE /collections/{id}を使用。名前は空白除去し一意。PATCHはnameのみ、DELETEは所属だけ解除する。GET /statusは素材数・使用量・形式対応・ローカル保存モードを返す。

エラーはApiError。409 conflict、404 not_found/missing_file、400 invalid_request、413 too_large、403 forbidden_origin。ImportItemのstateはready/duplicate/failed/staging/processing、codeはunsupported/corrupt/too_large/storage_error/interrupted/trashed_duplicate等。詳細messageは利用者向けで絶対パスを含めない。

ローカルAPIに認証はない。loopback限定の開発専用。本番未対応。Web用OpenAPIはAPIの `/openapi.json` で確認する。

GET /filter-optionsはDBに存在する原本拡張子の候補を返す。原本サイズはfiles.byteSize、追加日/更新日/撮影日はassetsの日時を使用。撮影日不明は空値として並ぶ（昇順は先頭、降順は末尾）。EXIF抽出は未実装。タイトルはSQLite NOCASE順（言語別の読み順ではない）。

POST /bulk-organizeはBulkOrganizeRequest（assetsのid/revision、entity=tags/collections、itemIds、mode=add/replace）を受け、BulkOrganizeResultを返す。最大100点。全件のrevision・存在・ごみ箱状態を確認し、単一トランザクションで更新。replaceの空itemIdsは全所属解除。POST /bulk-downloadはBulkDownloadRequestを受け原本ZIPを返す。最大100点・合計1GB。ファイル名に連番を付け同名衝突を避け、一時ZIPは応答後に削除する。ごみ箱は対象外。

## 通常とアーカイブ
Asset.archivedAtはnullable UTC日時。nullは通常、日時ありはアーカイブ。state（ready/deleting）とtrashedAtは独立し、ごみ箱から復元してもarchivedAtを保持する。原本取得・メタデータ編集だけでは保管状態を変更しない。

archiveの既定値はnormal。view=all/favoritesとコレクション検索は既定で通常のみ、archive=archived/allで切り替える。view=archiveはarchive指定にかかわらずアーカイブのみ、view=trashは両状態を含む。archiveもcursorの条件に含む。

- POST /assets/{id}/archive：ArchiveRequest（revision、archived bool）、Assetを返す。
- POST /bulk-archive：BulkArchiveRequest（assetsのid/revision、archived bool）、ArchiveResult（updated件数）を返す。1〜100点、全件を検証して単一トランザクションで変更する。
- GET /collections/{id}/archive-summary：CollectionArchiveSummary（normalCount、archiveCount、token）を返す。全所属素材のうちごみ箱・削除処理中を除いた件数。
- POST /collections/{id}/archive：CollectionArchiveRequest（archived bool、token）、ArchiveResultを返す。全ページ・フィルター外を含むリモート所属素材が対象。確認時の所属・revision・保管状態が変わった場合は409で全件変更を拒否する。100点の選択上限は適用しない。

同じ保管状態への操作はrevision・updatedAtを変更せずupdated=0。ごみ箱の素材への個別・選択操作は400。GET /statusは総assetCountに加えnormalCount、archiveCountを返し、ごみ箱を除外する。byteSizeはごみ箱を含む全ファイル容量で、アーカイブでは減らない。

## 原本の所在（開発用）
Asset.storageLocationはlocal / development-remote、originalOwnershipはmanaged / reference。ローカルSQLiteはv4。既存v3素材はdevelopment-remoteへ分類するが原本は変更しない。新規素材はlocal。アーカイブはリモート専用。
GET /assetsのlocation=all（既定）/local/development-remoteはcursor条件にも含む。
POST /import-local-directoryは固定フォルダobjects/local-originalsを参照登録しImportJobを返す（新規100件まで）。任意パスの指定は受けない。参照の移動はmissing、サイズ・更新日時変更はchanged。changed原本は取得・ZIP・再生成を拒否。参照素材の完全削除は参照元を残す。
GET /statusは従来のmode=localに加えstorageMode=development-hybrid、localDirectory、localCount、remoteCountを返す。全て開発PC内の保存で、AWS接続・端末間共有・容量解放は未実装。

## 手動同期・転送（SQLite v6）
GET /storage-rootsはStorageRoot配列。stateはready/missing。POST /sync-directoryはSyncDirectoryRequest（path絶対パス、rootId nullable）、SyncDirectoryResult（rootId、added、matched、moved、changed、missing、failed、limited）を返す。rootId指定で移動したフォルダを再登録できる。folder_missingは404。新規候補100件までで一致ファイルは次回の上限を消費しない。原本の自動改訂・削除はしない。
POST /assets/{id}/transferはTransferRequest（revision、destination local/development-remote、removeLocal bool）を受けAssetを返す。localではremoveLocal=false、development-remoteではtrueを必須とする。ごみ箱は400、revision／変更競合は409。remoteAvailableは対応するリモートコピーの登録有無、localCleanupPendingは転送成功後のローカル整理残り。再試行は最新revisionで同じremote転送を要求。転送・ダウンロード先は照合し、原本を保持し、ローカル転送時はarchivedAtを解除する。S3には接続しない。

SQLite v7: ローカルの既存archivedAtを解除しrevisionを更新する。個別・選択アーカイブにローカルが含まれる場合は400で全件拒否。コレクションsummaryとtokenはリモート素材のみを対象とする。

Mac手動アップロード: `MediaFolder`・`FolderUploadItem`・`FolderUpload`はフォルダ親子関係と転送の公開DTO。`GET /folder-uploads`、`POST /folder-uploads/scan`、`GET /folder-uploads/{id}`、`POST /folder-uploads/{id}/start`（confirmUpload=true必須）、`POST /folder-uploads/{id}/pause`。既存Asset DTOと独立。詳細は [仕様](../docs/MANUAL-FOLDER-UPLOAD.md)。

S3フォルダ閲覧: `GET /folder-library`はroot単位の最新保存完了FolderUpload一覧。`GET /folder-library/{planId}/items/{itemId}/content`は照合した原本（thumbnail=trueでMac原本由来の派生、download=trueで添付）。未完了カタログの原本は取得不可。

本人専用クラウド読取: ReadRoot/ReadCatalog/ReadItem/ReadURLが `/library` と `/catalogs/{root}/{upload}`、登録item用GET URLのDTO。署名URLはカタログに含めず、明示取得時の短いレスポンスだけに含む。iOSには書き込みAPIがない。

マイショートはsort=randomとseed（1–128文字）を指定。seedはcursorの条件にも含む。同じseedとAsset IDから安定したランダム順位を生成する。kindにvideoを追加。動画displayは閲覧用video/mp4、thumbnailはimage/jpeg、生成不能はfailedとerrorを返す。既存の文字列型契約を維持する。[動画仕様](../docs/MY-SHORT.md)。
