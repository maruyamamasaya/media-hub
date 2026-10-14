# iOSキャッシュの即時表示
## Request
通常画像をキャッシュから先に表示し、隠したフォルダは解除中のみ再利用、フォルダ情報も再利用する。
## Investigation
従来は画像キャッシュの参照より先に署名URL取得を待っていた。カタログも画面ごとに再取得していた。
## Changes
セッション内の取得済みカタログでアクセスを確認してキャッシュを先に表示。フォルダ情報をメモリ再利用し、30秒間隔を上限にフォルダ単位の背景更新をまとめる。更新結果を画面へ反映。再ロックでカタログ・表示を破棄し、古いカタログからの取得を拒否。権限拒否・ロックrevision変更でも再ロック。原本ハッシュ検証・暗号化経路・512MB上限は維持。Vesperaへ既存署名とデータを保持して更新。
## Files Changed
ios/PhotoHub/CloudViewer.swift、ios/PhotoHubTests/IntegrationTests.swift、docs/S3-READER.md、CURRENT.md、TESTING.md、本記録。
## Validation
署名なしSimulator／iphoneosビルド成功。追加のSimulator統合テスト1件成功（通信なしのカタログ／画像再利用、未解除フォルダ・再ロック・ログアウトの拒否）。初回は画像の画面倍率を考慮しないテスト期待値で失敗し修正。文書verify・diff空白チェック成功。署名deep strict検証・実機install成功。実機launchはLockedで失敗。
## Result
キャッシュがある画像では表示前の署名URL通信を除去。改善版はVesperaへインストール済み。
## Remaining Issues
端末を解除して最新版の起動と体感速度を本人が確認する。初回取得・未キャッシュ画像は通信が必要。背景更新の成功・権限変更時の実ネットワーク確認は未実施。フォルダ情報は再起動・背景再ロック後に再取得する。
