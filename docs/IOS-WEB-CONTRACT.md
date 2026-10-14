# WebとiOSの共通仕様・確認待ち

## 共通の正本
[API契約](../contracts/README.md)とasset.schema.jsonがAsset/File/Tag/Collection/Page/Importの正本。Webの型と `Sources/AssetLibraryContract/Models.swift` を同じスクリプトから生成する。`--check`が両者のずれを検出する。Swift Packageに独立したAssetLibraryContract製品、読み取り用APIClient、同じJSON例のデコード・再エンコードテストを追加した。

現環境はWindowsでSwift/Xcodeなし。生成一致は確認できるが、Swiftのコンパイル・Codable実行・実機UI・ネットワークは未検証。既存iOS画面とSQLiteはPhotoモデルを使ったままで、新Webと同じ機能がすでに動くわけではない。

## 接続時の方針
1. MacでSwift Package全テスト、iOSビルドを実行し、共通JSONをデコードする。
2. iOSにAssetLibraryContractを組み込み、一覧・詳細取得を共通APIへ接続する。初期クライアントは取得のみで、追加/整理は契約に沿って別途実装する。
3. 将来の本番認証ヘッダーを追加し、URLSessionとCognitoのライフサイクルを統合する。今のローカルAPIを無認証のままLAN公開しない。
4. iOSのSQLiteはキャッシュへ役割を整理し、APIのAsset ID/revisionと関連づける。オンライン正本と端末内未送信素材を区別する。
5. Photo→Asset、Album→Collection、Membership→CollectionAssetの変換を専用移行として実装し、事前バックアップ・dry run・件数とハッシュ照合を行う。
6. 旧users/{sub}/photosキーと新libraries/{libraryId}/assetsキーの対応表を持つ。旧JSON version 1をそのまま新DBへ書き込まない。

既存iOSは全3オブジェクト一致をuploaded条件にするが、新Webは原本保存と派生失敗を別状態にする。将来のiOS転送も固定3件ではなくFileのrole/stateを読む構造へ移す。日時はUTC文字列、未知kind/role/stateは読み込み失敗にせず対応外として表示する。完全削除とごみ箱、コレクション所属解除と素材削除を区別する。

## 検証のゲート
iOSのPhotoGridにも設定アイコンと統合シートを追加。旧Photoが持つ原本拡張子・お気に入りの絞り込み、追加日・撮影日・ファイル名・原本サイズの昇降順に対応。タグ・種別・更新日は旧モデルが持たないため、共通Asset API接続時にWebと揃える。現段階で存在しない項目を仮データで補わない。Macでシート・各並び順・アルバム内絞り込み・Dynamic Type・VoiceOverを確認する。
一覧の表示方針は正方形・狭い間隔・画像下部の半透明タイトル帯。Webは10px、既存iOSのPhotoGridは基準10pt（Dynamic Type対応）で名前を1行表示する。タグは一覧に表示せず、Webの保存・詳細編集・検索には保持する。既存iOSはPhoto.filenameを表示し、Assetのタグ連携は接続工程で実装する。iOSの表示変更はWindowsではビルド・実機未検証。

| タイミング | 必須の確認 | 現在 |
| --- | --- | --- |
| 今回のWeb実装 | スキーマ例・API実レスポンス・Web/Swift生成一致 | 自動検証対象 |
| Macが使える時 | swift test、共通DTO round trip、APIClientのURLとエラーデコード | 未実行 |
| iOS接続後 | 一覧・追加・整理・検索・取得・ごみ箱・復元が共通API契約と一致 | 未実装・未実行 |
| iPhone実機 | 写真限定権限、原本保全、共有からの追加、ピンチ・回転・VoiceOver | 未実行 |
| 共通サーバー接続後 | Web→iOS/iOS→Web更新、revision競合、ログイン期限、オフラインと再接続 | 未実行 |
| 本番前 | 容量不足・中断・欠損・大規模スクロール・バックアップから移行 | 未実行 |

Webの狭幅テストはレスポンシブ確認であり、iOS実機成功の証拠にしない。既存の [実機チェックリスト](DEVICE-CHECKLIST.md) も維持する。

## マイショート（2026-10-13）
旧Photo版に縦閲覧・お気に入り/アルバム/詳細連携・PhotoKit動画原本取り込み・AVFoundation派生・AVPlayer再生を追加。開発用保存はplaybackキーを追加してバックアップ/復元時にも取得可能。既存AWSへの新規動画転送は拒否する。タグ/ごみ箱/アーカイブ・Web素材同期は未実装。Swiftビルドと実機は未検証。[仕様と保管の限界](MY-SHORT.md)。
