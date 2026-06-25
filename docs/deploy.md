# blt-server デプロイ手順

`Dockerfile` から同一イメージを作り、Fly.io（クラウド）と self-host（任意の Docker ホスト）の双方で動かす。設計の背景は `blt-server-roadmap.md`「クラウド構成」を参照。

## 環境変数

| 変数 | 役割 | デプロイでの扱い |
|---|---|---|
| `BLT_HOST` / `BLT_PORT` | bind（既定 `0.0.0.0:8080`） | Dockerfile 既定。通常変更不要 |
| `BLUE_TICKER_ASSETS_PATH` | EDINET コード CSV の場所（既定 `/app/assets`） | Dockerfile 既定 |
| `BLUE_TICKER_USER_DATA_PATH` | キャッシュ・設定の永続先（既定 `/data`） | Volume をここにマウント |
| `BLT_EDINET_API_KEY` | EDINET API キー | **secret**（必須） |
| `BLT_AUTH_TOKEN` | Bearer トークン。設定時のみ `/v1` を保護 | **secret**（公開時は必須） |
| `DATABASE_URL` | Neon Postgres 接続文字列 | **secret**（未設定なら DB なしのステートレス動作） |

`/healthz` は認証不要で `{"status":"ok"}` を返す（ヘルスチェック用）。

## Fly.io

```bash
# 1. 初回のみアプリ作成（fly.toml の app 名が重複する場合はここで変更）
fly launch --no-deploy --copy-config --name blt-server --region nrt

# 2. シークレット注入
fly secrets set \
  BLT_EDINET_API_KEY=xxxxx \
  BLT_AUTH_TOKEN=$(openssl rand -hex 32) \
  DATABASE_URL='postgres://...neon.tech/...?sslmode=require'

# 3. 永続 Volume（/data）。nrt に作成
fly volumes create blt_data --region nrt --size 1

# 4. デプロイ
fly deploy

# 5. 初回データ同期（Stage 1 書類一覧 → Neon）。稼働マシン上で実行
fly ssh console -C "/app/blt-server sync --from 2024-01-01"

# 6. 取り込み（Stage 3 数値 fact ＋ Stage 4 計算済み財務サマリ → Neon）。--limit で分割推奨
fly ssh console -C "/app/blt-server ingest --limit 50"
```

`ingest` は Stage 3（XBRL 数値 fact → `edinet_xbrl_facts`）に続けて Stage 4（計算済み財務サマリ → `company_financials`）を実行する。Stage 4 計算は HTML 依存抽出・waterfall を含みメモリを使うため、shared-cpu-1x/1gb の Fly 上で大量に走らせると OOM しうる。**重い初回バックフィルはローカル（または余裕のあるマシン）から `DATABASE_URL` を Neon に向けて実行する**運用を推奨（下記「Neon 接続の E2E 検証」と同手順）。REST サーバー（Fly）は `company_financials` を読むだけなので financials は OOM しない。

ヘルスチェック・HTTPS・証明書は `fly.toml` と Fly が処理する。独自ドメインは `fly certs add <domain>`。

## self-host（Docker）

```bash
# ビルド
docker build -t blt-server .

# 起動（キャッシュ永続化のため /data をボリュームマウント）
docker run -d --name blt-server -p 8080:8080 \
  -e BLT_EDINET_API_KEY=xxxxx \
  -e BLT_AUTH_TOKEN=xxxxx \
  -e DATABASE_URL='postgres://...' \
  -v blt_data:/data \
  blt-server

# 初回同期 + Stage 3 取り込み
docker exec blt-server /app/blt-server sync --from 2024-01-01
docker exec blt-server /app/blt-server ingest --limit 50
```

## 定期同期

`blt-server sync` / `ingest` はワンショット。定期実行は Fly スケジューラ（`fly machine run ... --schedule`）または self-host の cron / launchd で回す。`sync`（引数なし＝前回 `synced_through` から当日まで）→ `ingest`（未取り込み・旧バージョン書類のみ）の順に実行する。

## Neon 接続の E2E 検証

実 DB に対する検証は 2 段で行う。CI/ユニットテストはインメモリ SQLite までのため、Postgres 固有挙動（`.json`→JSONB・索引・String PK）と実パイプラインは別途確認する。

### 1. Postgres スキーマ検証（ローカル Docker・EDINET 不要）

マイグレーション・JSONB round-trip・索引を実 Postgres で検証する opt-in 統合テスト（`PostgresIntegrationTests`、`BLT_TEST_POSTGRES_URL` 未設定なら skip）。

```bash
docker run -d --name blt-pg -e POSTGRES_PASSWORD=blt -e POSTGRES_DB=blt -p 55432:5432 postgres:16-alpine
BLT_TEST_POSTGRES_URL='postgres://postgres:blt@localhost:55432/blt?sslmode=disable' \
  swift test --filter PostgresIntegrationTests
docker rm -f blt-pg
```

期待: `facts` カラムが `jsonb`、`idx_edinet_documents_edinet_code`/`_sec_code` が存在、Stage 1 冪等 upsert・Stage 3 JSONB round-trip・staleness skip が緑。

### 2. 実 Neon フルパイプライン（要シークレット・EDINET ネットワーク）

`DATABASE_URL`（Neon・`?sslmode=require`）と `BLT_EDINET_API_KEY` を設定し、ローカルバイナリで sync→ingest→financials を通す。

```bash
export DATABASE_URL='postgres://...neon.tech/...?sslmode=require'
export BLT_EDINET_API_KEY=xxxxx

# 起動時に autoMigrate がスキーマを適用（DATABASE_URL があれば自動）
swift run blt-server sync --from 2025-04-01   # Stage 1: 書類一覧 → edinet_documents
swift run blt-server ingest --limit 5         # Stage 3 数値 fact → edinet_xbrl_facts ＋ Stage 4 計算済み → company_financials

# DB に入ったことを確認（psql）
psql "$DATABASE_URL" -c "SELECT count(*) FROM edinet_documents;"
psql "$DATABASE_URL" -c "SELECT doc_id, cache_version, jsonb_typeof(facts) FROM edinet_xbrl_facts LIMIT 5;"
psql "$DATABASE_URL" -c "SELECT code, cache_version, requested_years FROM company_financials LIMIT 5;"

# financials 読み取り（Stage 4 格納済みなら DB から、無ければライブ計算へフォールバック。公開契約は不変）
swift run blt-server &                          # ローカル起動（既定 127.0.0.1:3000）
curl -s 'http://127.0.0.1:3000/v1/companies/7203/financials?years=3' | jq '.schema_version, .years[0].fy_end'
```

期待: `edinet_documents`/`edinet_xbrl_facts` に行が入り、`facts` が `jsonb`、financials が 200 + `schema_version=2`。Neon は東京リージョン外（片道 ~100ms）だが書き込みはバッチ・読み取りはキャッシュ＋計算済み JSON のため許容（`blt-server-roadmap.md`「クラウド構成」）。
