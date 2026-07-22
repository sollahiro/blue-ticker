# AGENTS.md

プロジェクトの全体像・ビルド/テスト・ターゲット構成は `CLAUDE.md` と `docs/`（`architecture.md` ほか）を正本とする。以下は Cursor Cloud 環境固有の補足のみ。

## Cursor Cloud specific instructions

このリポジトリは Swift 6 / SwiftPM 製（配布 CLI `ticker` と REST サーバー `blt-server`）。開発環境は Linux（Ubuntu 24.04）。Swift 6.1 ツールチェーンは swiftly で導入済みで、`~/.profile`（`~/.local/share/swiftly/env.sh` を source）経由で PATH に入る。非ログインシェルで `swift` が見つからない場合は `. "$HOME/.local/share/swiftly/env.sh"` を先に実行する。

- **Linux での `swift build` / `swift test` には必ず `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility` を付ける**（swift-nio の `_NIOFileSystem` が Linux で `import CSystem` を欠くための一時回避策）。付けないと Vapor 依存のビルドが失敗する。背景は `.agents/rules/project/dependencies.md`「Linux 互換」と `docs/blt-server-roadmap.md`「Linux ビルドの既知の問題」、適用例は `.github/workflows/ci.yml` の `swift-linux` ジョブを参照。macOS では不要。
- **`blt-server` は起動時に非空の `BLT_EDINET_API_KEY` を要求する**（未設定だと即終了）。EDINET を実際に叩くのは live filings / `sync` / `ingest` のみで、企業検索・業種一覧（`/v1/companies`・`/v1/sectors`）はローカルの `assets/EdinetcodeDlInfo.csv` を読むため EDINET へ接続しない。ローカル起動・検索系の動作確認だけなら `BLT_EDINET_API_KEY=dev-local-dummy` のようなダミー値で十分（本物の鍵は EDINET 実アクセス時のみ必要）。
- サーバーはローカル既定で `127.0.0.1:3000` を bind する（`BLT_HOST` / `BLT_PORT` で上書き。Docker 既定は `0.0.0.0:8080`）。`DATABASE_URL` 未設定ならステートレス（DB なし）で起動し、財務系 read は 404/503 になる。`CF_ACCESS_TEAM_DOMAIN` 未設定なら無認証モード（ローカル開発専用）。
- 動作確認例: `BLT_EDINET_API_KEY=dev-local-dummy ./.build/debug/blt-server` で起動 →
  `curl -s http://127.0.0.1:3000/healthz` /
  `curl -s "http://127.0.0.1:3000/v1/companies?q=<社名>"`。
  配布 CLI からは `BLT_SERVER_URL=http://127.0.0.1:3000 ./.build/debug/ticker search <社名>` でローカルサーバーに接続できる（既定は remote 本番で `ticker login` が必要）。
- DB 統合（`PostgresIntegrationTests`）や EDINET/LLM を伴うスモークテストは、それぞれ `BLT_TEST_POSTGRES_URL` / `BLT_EDINET_API_KEY`（実鍵）/ `XAI_API_KEY` 未設定時は自動 SKIP される（`swift test` は鍵なしでも緑になる）。
