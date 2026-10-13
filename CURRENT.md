# 現在地

確認日: 2026-10-13（日本時間）

- **Project:** photo-hub。個人用素材ライブラリ。Asset Libraryは仮称、正式名称は未決定。
- **現在のフェーズ:** [Web実装プロンプト](docs/web-phases/README.md)のローカル6段階を実施。Web版で使い勝手を確認できる状態。既存iOS写真版は保持。
- **実装済み:** React/TypeScript Web、PythonローカルAPI、SQLite、原本取り込み、派生画像（透過PNG/非透過JPEG）、小画像の中央原寸表示・拡大切り替え、一覧・詳細・取得、タグ・メモ・検索・コレクション・お気に入り、種別/複数タグ/拡張子フィルター、日時/タイトル/サイズ並び替え、複数選択と一括所属設定・原本ZIP取得、リモート専用の通常／アーカイブの個別・選択一括・コレクション全体切り替え、ごみ箱・復元・完全削除、失敗再試行、共通契約とSwift DTO/読み取りクライアント。以前のiOS写真管理と本番用認証・署名API・S3テンプレートも保持。
- **マイショート:** Web／Windowsに縦閲覧・ランダム履歴・整理連携・動画原本取り込みと任意FFmpeg派生生成を追加。Chromium操作・派生のみの通信を確認。iOS旧Photo版にもタブ・AVFoundation動画派生・再生・開発用保存/復元を追加（Swiftビルド・実機未検証）。実FFmpeg変換は未検証。[対応範囲・キャッシュ](docs/MY-SHORT.md)。
- **進行中:** ローカルWeb版の操作評価とMac・Windowsアプリ試作。共有UI・API子プロセス管理・独立ライブラリを実装。Windowsの自動描画・二重起動・原本保持を確認。Mac向け起動・メニュー・Dock再表示を追加し、実機確認待ち。起動は [アプリ試作手順](docs/DESKTOP-OPERATIONS.md)、Webは [WEB-OPERATIONS.md](docs/WEB-OPERATIONS.md)。AWSは保留。
- **設計メモ:** [Mac・Windowsアプリ設計](docs/DESKTOP-DESIGN.md)。React UI共有とElectron＋Python APIで両OSの開発用試作を整備。Mac実機は未検証、ランタイム同梱・署名配布は未実装。[通常／アーカイブの2状態案](decisions/0006-normal-and-archive-storage.md)はローカルWeb/APIで実装・検証済み。S3保存クラス変更は未実装。
- **保管方針:** [ローカル主体の原本保管と端末間共有](docs/STORAGE-DESIGN.md)へ設計更新。共有する原本は照合・共有登録後にリモートへ移し、ローカルを整理。アーカイブはリモート専用。ローカルへ戻すと通常扱い。AWSは後工程。所在バッジ・所在フィルター・固定ローカルフォルダ参照登録をWeb／Windows試作に追加。既存原本はPC内の開発用リモートとして保持し、新規原本はローカル。確認画像を配置。Windowsの明示的な-WebLibrary起動で既存Web素材を複製せず実機確認できる。素材詳細の設定内に模擬アップロード・ローカルダウンロードを追加。任意画像フォルダの手動同期・移動先の再指定・ハッシュ照合と欠損通知を実装。PC全体の容量解放はAWS接続後。設定はリンク一覧へ整理し、同期・保管管理・バックアップ・テスト素材を専用ページへ分離。
- **iOSアイコン:** 深緑の写真アルバム図案をAppIconとして追加。署名なしiOS Simulator／実機向けビルドで組み込み確認済み。Vesperaへインストール・プロセス起動確認済み。実機ホーム画面と写真操作は確認待ち。原稿再描画は `scripts/render-app-icon.swift`、結果は [作業記録](sessions/2026-10-08-app-icon.md)。
- **未実装:** Web/iOS接続、共有メタデータと複数端末同期、AI、3D専用管理、実AWSデプロイ、CI/CD。iOS実機の画面・機能検証は未実施。
- **既知の問題:** WebのHEICは原本保管のみ、EXIF撮影日時抽出は未実装。Swift新モジュールのビルド・iOS実機はWindows環境で未検証。Web原本の退避は停止中のフォルダ全体バックアップが必要。
- **技術的負債:** 取り込みは逐次・フォルダ追加は同期。SQLite一覧は素材ごとの関連取得で1,000件API測定約0.40秒/60件。大規模ブラウザスクロール・iOS性能は未測定。旧iOSデータと新Webの移行は別工程。
- **次に行うこと:** Windows試作で手操作の追加・整理・保存・終了を評価し、OS保存連携と起動中表示を整える。Webの操作評価も継続。[iOS共通仕様と確認待ち](docs/IOS-WEB-CONTRACT.md)に従ってMac/iPhone検証へ進む。AWSはUI検証後、構成・費用を確認して進める。

設計は [ARCHITECTURE.md](ARCHITECTURE.md)、検証は [TESTING.md](TESTING.md)、段階別プロンプトは `docs/phases/`、作業結果は [sessions/](sessions/README.md)。
