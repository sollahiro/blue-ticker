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
- DB 統合（`PostgresIntegrationTests`）や EDINET/LLM を伴うスモークテストは、それぞれ `BLT_TEST_POSTGRES_URL` / `BLT_EDINET_API_KEY`（実鍵）/ `XAI_API_KEY` 未設定時は自動 SKIP される（`swift test` は鍵なしでも緑になる）。`PostgresIntegrationTests` は使い捨ての検証用 Postgres（`BLT_TEST_POSTGRES_URL`）を前提とし、下記 Cloud Neon Secrets とは別物。
- **Neon 接続は Secrets で三本立て**（段階は使い捨て → 本番 read-only → 本番書き込み。アプリ本体が読むのは常に `DATABASE_URL` のみで、本番系 2 本はエージェント／手動が明示オプトインする）:
  1. **`DATABASE_URL`（使い捨て・既定の書き込み先）**: 書き込み検証用の使い捨て Neon ブランチ（本番 `api.sollahiro.com` の DB とは隔離。値は運用で変わりうる）。このブランチ向けなら `blt-server sync` / `ingest` / `master-data-upload` を実行して問題ない。live EDINET 経路だけを確認したいなら書き込みを伴わない `swift run TickerDev summarize <code>`（in-process 解析）でも良い。探索・実装検証・スキーマやり直しは常にここ。
  2. **`BLT_PROD_DATABASE_URL`（本番 read-only）**: 本番 Neon の **読み取り専用** 用（未設定なら無視）。`psql "$BLT_PROD_DATABASE_URL" -c 'SELECT ...'` や件数確認など **SELECT のみ**。`sync` / `ingest` / `master-data-upload` / `DROP SCHEMA` / スキーマ変更、および `DATABASE_URL` にこれを入れてサーバー起動する（起動時 `autoMigrate` が走る）ことは禁止。本番データでの read 検証が必要なときだけ使う。
  3. **`BLT_PROD_WRITE_DATABASE_URL`（本番書き込み）**: 本番 Neon への **意図的な書き込み** 用（未設定なら無視。Fly / Mac launchd が使う本番接続と同じ系統）。**ユーザーが本番書き込みを明示したときだけ**、コマンド単位で `DATABASE_URL="$BLT_PROD_WRITE_DATABASE_URL" blt-server sync|ingest|master-data-upload ...` のように一時上書きする。既定の `DATABASE_URL` をこれに差し替えない。`DROP SCHEMA` / スキーマ破壊、および「試しに」の探索的 ingest は禁止（先に使い捨て段で検証する）。未設定のまま本番書き込みを求められた場合は Secret 追加を案内して止まり、`BLT_PROD_DATABASE_URL` へ書き込まない。
  - **新規/空の Neon ブランチでハマる `autoMigrate` の注意点**（使い捨て `DATABASE_URL` 向け。本番系 2 本では絶対に実行しない）: テーブルは存在するのに `_fluent_migrations` が空（過去のスキーマ痕跡が残った空ブランチ等）だと、起動時 `autoMigrate` が `CREATE TABLE ... relation "edinet_documents" already exists`（SQLSTATE 42P07）で失敗し、5 回リトライ後にサーバーが終了する。データが無い（空）ことを確認のうえ `psql "$DATABASE_URL" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'` で作り直せば、次回起動時に `autoMigrate` がテーブル作成とマイグレーション記録をやり直して正常起動する（データが入っている DB では絶対に実行しないこと）。
