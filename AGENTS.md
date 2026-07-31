# AGENTS.md

エージェント向けの作業合意。ビルド・ターゲット構成の正本は `CLAUDE.md`、運用ルール（実装前後・公開面保護・ブランチ・ドキュメント・コミット規約など）は `.agents/rules/`、アーキテクチャは `docs/`。

## 原理原則

### コンテキスト

最も希少な資源はコンテキストである。すべての判断は認知負荷と情報量を最小化する方向で行う。指針・ドキュメント・本ファイル自身も短く保つ。

### 実データ・実測主義

モックや推測より、EDINET / Neon / 本番 read の実データと件数で判断する。カバレッジや品質ゲートは計測してから次工程へ進む。

### Git First

Git を唯一の Source of Truth とする。永続化すべき判断・文脈は Git もしくは memory に記録し、一時情報は残さない。履歴の詳細は Git に委ねる。

### 責務分離とモジュール境界

ロジックやサービスは入れ替え可能なモジュールとして設計する。ターゲット境界（`CLAUDE.md`）を守る: Core は Vapor/Fluent を参照しない。Web/DB は `BltServerCore` に閉じ込める。同一モジュール内のディレクトリ責務もレビューで担保する。

### 開発哲学

機能追加 → 抽象化 → 単純化を繰り返す。抽象化は実際に重複が発生してから行う（予測では行わない）。コードは少ないほどよいが、必要な機能・振る舞いは必ず満たす。より単純な設計があれば既存実装に固執せず置き換える。要求がない段階で拡張機構は作らない。

### テスト哲学

テストは仕様を保証するために存在する。実装ではなく振る舞いを検証する。境界値・異常系を重視し、実装詳細（呼び出し順や内部構造）はテストしない。

## 機能の実装サイクル

新機能・Stage 拡張は次の順で進める。ここでいうバンプは Neon `cache_version`（`blueTickerVersion` ではない。詳細は `.agents/rules/project/versioning.md`）。公開範囲（REST/MCP 解禁の有無など）は機能ごとに都度確認する。

1. **日経225限定で本番書き込み** — `assets/nikkei225.csv` / `priorityIngestCodes()` で母集団を絞り、`BLT_PROD_WRITE_DATABASE_URL` 経由で本番へ ingest（探索的な試し書きはしない）。
2. **最新年度が揃ったらロジック改善（バンプしない）** — 日経225のうち最新有報が取れた社を母数に 100% を見る。欠測は無視せず正当欠測か不具合かを確認する。改善しても `cache_version` は上げない。
3. **使い捨てブランチで検証** — 改善後の書き込み・読み出しは `DATABASE_URL`（schema only 可）で確認する。
4. **問題なければ公開し、225 全件取得** — 公開可否・公開面は都度確認。問題なければ日経225を全件 ingest する。
5. **ロジック改善（バンプしない）** — 225 全件を見たうえでの修正。`cache_version` は上げない。
6. **不審フラグは手動 ingest** — `needs_review`・あいまい失敗・異常な欠測など不審なものは通常巡回に任せきりにせず、手動 ingest で更新する。
7. **225 全体で問題なければ全銘柄へ拡張** — 対象母集団を広げる。
8. **ロジック改善（バンプする）** — 全銘柄展開に伴うロジック定着時は該当 Stage の `cache_version` を上げ、再 ingest で収束させる。

## 監査レビューとモデル分担

### 監査レビュー（実装後）

大幅な変更・リファクタリング・効率化／簡略化の後は、実装したセッション自身ではなく別のレビュー主体に監査させ、結果を是々非々で判断する（単一ファイルでも対象）。

- **監査に渡すもの**: 仕様（契約）と diff のみ。「なぜこの実装が良いか」を説明して結論へ誘導しない。
- **問い**: 「この仕様を diff は満たしているか」「既存機能を壊していないか」の2点に絞る。
- **タイミング**: ブランチ／ワークツリーを切った変更は main へマージする前に済ませる。マージ後に回すのは漏れ（ブランチ高度＝レビューの品質ゲート）。
- **実行方法**: サブエージェント（`Agent` / `Task` ツール）に依頼する。Cursor CLI 経路は使わない。

### モデル分担

| 作業 | モデル |
|---|---|
| ユーザーとの基本的なやり取り・設計判断・実装（本体） | Grok 4.5 |
| 判断の質が要る監査レビュー | Grok 4.5、または難易度に応じて上位モデル |
| サブエージェントによる実装 | Composer 2.5 |
| 機械的な探索・並列調査 | Grok 4.5 |

表は「その作業を実行するモデル」を指定する。本体セッションが表と異なる場合でも、対象作業は表通りのモデルへ委譲する（Cloud Agent でも同じ分担）。

## Cursor Cloud

Swift 6 / SwiftPM（`blt-server` / `TickerDev`。配布 CLI `ticker` は廃止）。Linux（Ubuntu 24.04）。Swift は swiftly（非ログインシェルでは `. "$HOME/.local/share/swiftly/env.sh"`）。

- **Linux の `swift build` / `swift test`** には必ず `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility` を付ける（swift-nio `_NIOFileSystem` の Linux 回避。背景は `.agents/rules/project/dependencies.md` / `docs/blt-server-roadmap.md`、例は `.github/workflows/ci.yml` の `swift-linux`）。macOS では不要。
- **`blt-server` は非空の `BLT_EDINET_API_KEY` が必要**。EDINET 実アクセスは live filings / `sync` / `ingest` のみ。企業検索・業種一覧はローカル `assets/EdinetcodeDlInfo.csv`。ローカル起動だけなら `BLT_EDINET_API_KEY=dev-local-dummy` で可。
- 既定 bind は `127.0.0.1:3000`（`BLT_HOST` / `BLT_PORT`）。`DATABASE_URL` 未設定ならステートレス。`CF_ACCESS_TEAM_DOMAIN` 未設定なら無認証（ローカル専用）。動作確認: `BLT_EDINET_API_KEY=dev-local-dummy ./.build/debug/blt-server` → `curl -s http://127.0.0.1:3000/healthz`。本番機械アクセスは Access Service Token（`docs/api-auth.md` / `docs/deploy.md`）。
- DB 統合（`PostgresIntegrationTests`）や EDINET/LLM スモークは `BLT_TEST_POSTGRES_URL` / 実 `BLT_EDINET_API_KEY` / `XAI_API_KEY` 未設定時 SKIP（`swift test` は鍵なしでも緑）。`BLT_TEST_POSTGRES_URL` は下記 Neon Secrets とは別物。

### Neon Secrets（三本立て）

アプリ本体が読むのは常に `DATABASE_URL` のみ。本番系は明示オプトイン。実装サイクル上の本番書き込みは `BLT_PROD_WRITE_DATABASE_URL` をコマンド単位で渡す。

1. **`DATABASE_URL`（使い捨て）** — 既定の検証用ブランチ（schema only 可。本番とは隔離）。探索・改善検証・スキーマやり直しはここ。`sync` / `ingest` / `master-data-upload` 可。live 解析だけなら `swift run TickerDev summarize <code>` でも可。
2. **`BLT_PROD_DATABASE_URL`（本番 read-only）** — SELECT / 件数確認のみ。書き込み・`DROP SCHEMA`・これを `DATABASE_URL` にしてのサーバー起動（`autoMigrate`）は禁止。
3. **`BLT_PROD_WRITE_DATABASE_URL`（本番書き込み）** — 実装サイクル上の本番 ingest や、ユーザーが明示した本番書き込みのみ。`DATABASE_URL="$BLT_PROD_WRITE_DATABASE_URL" blt-server ...` と一時上書きする。既定値の差し替え・`DROP SCHEMA`・未検証の探索的 ingest は禁止。未設定なら Secret 追加を案内して止まり、`BLT_PROD_DATABASE_URL` へは書かない。

**`autoMigrate` の 42P07**（使い捨て限定）: テーブルはあるのに `_fluent_migrations` が空だと起動失敗する。空データ確認のうえ `psql "$DATABASE_URL" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'` で作り直す。本番系では実行しない。
