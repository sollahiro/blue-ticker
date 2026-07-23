# AGENTS.md

プロジェクトの全体像・ビルド/テスト・ターゲット構成は `CLAUDE.md` と `docs/`（`architecture.md` ほか）を正本とする。以下は Cursor Cloud 環境固有の補足のみ。

## Cursor Cloud specific instructions

このリポジトリは Swift 6 / SwiftPM 製（REST サーバー `blt-server` と開発用 `TickerDev`。配布 CLI `ticker` は廃止）。開発環境は Linux（Ubuntu 24.04）。Swift 6.1 ツールチェーンは swiftly で導入済みで、`~/.profile`（`~/.local/share/swiftly/env.sh` を source）経由で PATH に入る。非ログインシェルで `swift` が見つからない場合は `. "$HOME/.local/share/swiftly/env.sh"` を先に実行する。

- **Linux での `swift build` / `swift test` には必ず `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility` を付ける**（swift-nio の `_NIOFileSystem` が Linux で `import CSystem` を欠くための一時回避策）。付けないと Vapor 依存のビルドが失敗する。背景は `.agents/rules/project/dependencies.md`「Linux 互換」と `docs/blt-server-roadmap.md`「Linux ビルドの既知の問題」、適用例は `.github/workflows/ci.yml` の `swift-linux` ジョブを参照。macOS では不要。
- **`blt-server` は起動時に非空の `BLT_EDINET_API_KEY` を要求する**（未設定だと即終了）。EDINET を実際に叩くのは live filings / `sync` / `ingest` のみで、企業検索・業種一覧（`/v1/companies`・`/v1/sectors`）はローカルの `assets/EdinetcodeDlInfo.csv` を読むため EDINET へ接続しない。ローカル起動・検索系の動作確認だけなら `BLT_EDINET_API_KEY=dev-local-dummy` のようなダミー値で十分（本物の鍵は EDINET 実アクセス時のみ必要）。
- サーバーはローカル既定で `127.0.0.1:3000` を bind する（`BLT_HOST` / `BLT_PORT` で上書き。Docker 既定は `0.0.0.0:8080`）。`DATABASE_URL` 未設定ならステートレス（DB なし）で起動し、財務系 read は 404/503 になる。`CF_ACCESS_TEAM_DOMAIN` 未設定なら無認証モード（ローカル開発専用）。
- 動作確認例: `BLT_EDINET_API_KEY=dev-local-dummy ./.build/debug/blt-server` で起動 →
  `curl -s http://127.0.0.1:3000/healthz` /
  `curl -s "http://127.0.0.1:3000/v1/companies?q=<社名>"`。
  本番機械アクセスは Access Service Token（`docs/api-auth.md` / `docs/deploy.md`）。
- DB 統合（`PostgresIntegrationTests`）や EDINET/LLM を伴うスモークテストは、それぞれ `BLT_TEST_POSTGRES_URL` / `BLT_EDINET_API_KEY`（実鍵）/ `XAI_API_KEY` 未設定時は自動 SKIP される（`swift test` は鍵なしでも緑になる）。`PostgresIntegrationTests` は使い捨ての検証用 Postgres（`BLT_TEST_POSTGRES_URL`）を前提とし、本番 `DATABASE_URL` とは別物。
- **`DATABASE_URL`（Secrets 経由）は書き込み検証用の使い捨て Neon ブランチを指す想定**（本番 `api.sollahiro.com` の DB とは隔離。値は運用で変わりうる）。使い捨てブランチである限り `blt-server sync` / `ingest` / `master-data-upload` をこのブランチへ実行して問題ない（本番には影響しない）。read 系（financials・filings 等）と起動時 `autoMigrate` はもちろん安全。live EDINET 経路だけを確認したいなら書き込みを伴わない `swift run TickerDev summarize <code>`（in-process 解析）でも良い。**もし `DATABASE_URL` が本番を指す設定になっている場合は、書き込み系コマンドは本番を汚すため実行しないこと。**
  - **新規/空の Neon ブランチでハマる `autoMigrate` の注意点**: テーブルは存在するのに `_fluent_migrations` が空（過去のスキーマ痕跡が残った空ブランチ等）だと、起動時 `autoMigrate` が `CREATE TABLE ... relation "edinet_documents" already exists`（SQLSTATE 42P07）で失敗し、5 回リトライ後にサーバーが終了する。データが無い（空）ことを確認のうえ `psql "$DATABASE_URL" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'` で作り直せば、次回起動時に `autoMigrate` がテーブル作成とマイグレーション記録をやり直して正常起動する（データが入っている DB では絶対に実行しないこと）。
