---
name: deploy
description: Fly / self-host / Cloudflare Tunnel・Access・GitHub Actions のデプロイと定常運用を行うときに使う。
---

# デプロイと運用

Neon write・RO 同期・訂正有報は `.agents/skills/production-ingest/SKILL.md`。リリース tag は `.agents/skills/release/SKILL.md`。

# blt-server デプロイ手順

同一 OCI イメージを Fly と self-host で使う。手元のビルド・実行は Apple `container`。構成は `docs/architecture.md`、認証方針は `docs/api-auth.md`。環境変数の薄い表も architecture。Neon 接続の正本は `.env.example`。

## 環境変数

| 変数 | 役割 |
|---|---|
| `BLT_HOST` / `BLT_PORT` | bind（既定 `0.0.0.0:8080`） |
| `BLUE_TICKER_ASSETS_PATH` | assets（既定 `/app/assets`） |
| `BLUE_TICKER_USER_DATA_PATH` | キャッシュ永続先（既定 `/data`） |
| `BLT_EDINET_API_KEY` | EDINET（**secret・必須**） |
| `CF_ACCESS_TEAM_DOMAIN` | 設定時 Access モード。公開デプロイでは**必須**（未設定＝無認証） |
| `CLOUDFLARE_TUNNEL_TOKEN` | 設定時のみ cloudflared 起動 |
| `DATABASE_URL` | プロセス束縛（未設定＝ステートレス）。手元は disposable、Fly ではその環境の Neon を直接指定 |
| `BLT_FEED_TREND_URL` / `BLT_FEED_TREND_TOKEN` | 匿名 Feed Trend カウンター（未設定＝emit なし。`GET /v1/feed/trend` は 503）。Worker は `api.*` の前段に置かない |

`/healthz` は認証不要。`cache_versions` でイメージの版を確認。

認証: `CF_ACCESS_TEAM_DOMAIN` あり → Access（エッジ信頼） / なし → 無認証（dev）。Bearer は廃止済み。

## Fly.io

```bash
fly launch --no-deploy --copy-config --name blt-server --region nrt
fly secrets set BLT_EDINET_API_KEY=xxxxx DATABASE_URL='postgres://...neon.tech/...?sslmode=require'
fly volumes create blt_data --region nrt --size 1
fly deploy
fly ssh console -C "/app/blt-server sync --from 2024-01-01"
# 重い ingest は Fly で OOM しうる → ローカルから Neon 向けに実行推奨
```

### GitHub Actions

| ワークフロー | 役割 |
|---|---|
| `ci.yml` | macOS/Linux test・iOS シミュレータ向けコンパイル（`ios` ジョブは `Apps/BlueTicker/` または `ci.yml` 差分時のみ、`macos-26`）・product/serviceless ガード |
| `deploy.yml` | CI 成功後の Fly 自動デプロイ（`v*` タグでは起動しない） |
| `feed-trend-worker.yml` | Feed Trend Worker デプロイ + Fly origin の URL/token |
| `edge-security-smoke.yml` | Access / serviceless 外形監視 |

repo secrets: `BLT_EDINET_API_KEY`（CI smoke）· `FLY_API_TOKEN` · `BLT_API_DOMAIN`。
Feed Trend Worker 追加: `CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID` · `BLT_FEED_TREND_TOKEN` · `AE_SQL_TOKEN`。

## self-host

```bash
container system start   # 未起動なら
container build -t blt-server .
container run -d --name blt-server -p 8080:8080 \
  -e BLT_EDINET_API_KEY=xxxxx -e DATABASE_URL='postgres://...' \
  -v blt_data:/data blt-server
container exec blt-server /app/blt-server sync --from 2024-01-01
container exec blt-server /app/blt-server ingest --limit 50
```

公開するなら Cloudflare Tunnel + Access を前段に置く。

## Cloudflare Access（方式A）

安全性は **Tunnel ＋ 公開ポート閉鎖（serviceless）＋ Access** の3点。Tunnel 維持のためマシンは always-on。

1. Tunnel 作成 → Public hostname `api.<domain>` → `http://localhost:8080`
2. Access アプリ（SSO / OTP）＋ **Service Auth**（機械用 Token）を OR 同居
3. Fly secrets: `CF_ACCESS_TEAM_DOMAIN` · `CLOUDFLARE_TUNNEL_TOKEN`
4. cloudflared は Dockerfile に同梱（版固定＋sha256）。トークン未設定なら blt-server のみ
5. `fly.toml` に `[http_service]` を戻さない（直アクセス経路が開く）

### Feed Trend Worker

匿名カウンターは Cloudflare Worker + Analytics Engine（`workers/feed-trend/`）。origin は URL + Bearer で POST するだけ（Fly 固有 API は使わない）。**この Worker を Tunnel の `api.*` / `mcp.*` に差し込まない。**

初回（手元 Mac。`.env` の `BLT_R2_ACCOUNT_ID` を流用可）:

```bash
# Cloudflare API token: Workers Scripts Edit + Account Analytics Read
export CLOUDFLARE_API_TOKEN=...
export AE_SQL_TOKEN="$CLOUDFLARE_API_TOKEN"   # 分けるなら Analytics:Read 専用
./scripts/feed-trend-ship.sh
```

以降の Worker コード変更は `main` への push で `.github/workflows/feed-trend-worker.yml` がデプロイし、同じ token で Fly secrets も更新する。GitHub secrets は `CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID` · `BLT_FEED_TREND_TOKEN` · `AE_SQL_TOKEN`（`FLY_API_TOKEN` は既存）。

手動の内訳:

```bash
cd workers/feed-trend
npx wrangler@4 deploy
npx wrangler@4 secret put TOKEN
npx wrangler@4 secret put ACCOUNT_ID
npx wrangler@4 secret put AE_SQL_TOKEN
fly secrets set BLT_FEED_TREND_URL='https://blt-feed-trend.<account>.workers.dev' \
  BLT_FEED_TREND_TOKEN='...'
```

### REST Service Token

```bash
curl -s "https://api.<domain>/v1/companies/7203/financials?years=1" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"
```

SSO は `Cookie: CF_Authorization=<jwt>`（`Cf-Access-Jwt-Assertion` だけでは通らない）。

レート制限はゾーン Free の短い period のみ。悪用が観測されたらプラン検討。

## MCP（Managed OAuth・開発用）

製品面ではない。ChatGPT Apps は凍結。ホストは解体しない。Cursor / 手元検証で使うときだけ触る。

`POST /`。Managed OAuth は**パス付きホスト不可** → 専用 `mcp.<domain>`。

1. Tunnel に `mcp.<domain>` → 同 origin
2. Access アプリ（パスなし）＋ Managed OAuth ON
3. 許可 IdP と redirect URI（`http://localhost/callback`・`http://127.0.0.1/callback` — ポートなしで登録）
4. discovery が 200、未認証 `tools/list` が 401 であることを確認

## 定期同期（ローカル）

重い ingest はローカル。スケジュール（launchd 等）はマシン固有のためリポジトリに置かない。**ジョブ編成・実行順**は `docs/ingest-policy.md`。本番 write は `.agents/skills/production-ingest/SKILL.md`。**limit / skip / write** は `scripts/jp/edinet/ingest.local.env`（gitignore。PR 不要）。

```bash
swift build -c release --product blt-server
cp scripts/jp/edinet/ingest.local.env.example scripts/jp/edinet/ingest.local.env
cp scripts/jp/edinet/ingest-run-cycle.local.example.sh \
   scripts/jp/edinet/ingest-run-cycle.local.sh
chmod +x scripts/jp/edinet/ingest-run-cycle.local.sh
# ingest.local.env で件数・skip を編集 → launchd / 手動
./scripts/jp/edinet/ingest-run-cycle.local.sh
```

`.env` は秘密・接続先、`ingest.local.env` は運用チューニング。employees/rd/goodwill は ingest 側で 30/回・日経225固定。

`assets/nikkei225.csv`（gitignore）: financials/filing-sections/statements と breakdowns の business/geography は処理順の優先。employees/rd/goodwill と statement-notes は対象母集団そのもの（未配置なら当該軸 0 件）。statements / business/geography の対象は上場全体。

## EDINET マスタ CSV

`assets/EdinetcodeDlInfo.csv` と Neon（`master-data-upload`）を**同時更新**。Neon に行があると Neon 優先（git だけ更新するとポーリングで巻き戻る）。

## Neon E2E

1. ローカル Postgres: `BLT_TEST_POSTGRES_URL` + `PostgresIntegrationTests`（CI linux でも実行）
2. 実 Neon: `.env` を load → `blt-server sync` → `ingest --limit` → `/v1/.../financials` が 200


# 外部サービス依存と運用保守


## 大前提

Neon / Fly Volume の内容は EDINET から `sync`→`ingest` で再導出可能。失われる一次データはない。全社再バックフィルは重いので移行時は dump/restore が現実的。

## サービス別

### Neon（代替容易）

結合点はプロセス束縛の `DATABASE_URL` のみ（手元では `BLT_NEON_DISPOSABLE_DATABASE_URL` 等を代入）。標準 Postgres（JSONB）。`withDbRetry` は cold start 対策で他 Postgres でも無害。切替: dump/restore または再 ingest → secret 差し替え。

### 内訳 LLM（切替容易）

結合点は軸共通の `LLM_PROVIDER`（`openai` / `xai`）と、プロバイダ×軸のキー（`OPENAI_*` / `XAI_*`）。現行は `LLM_PROVIDER=openai` + GPT-5.6 Luna。Grok に戻すときは `LLM_PROVIDER=xai`（xAI 側のキーはそのまま残せる）。`BASE_URL` 省略時はプロバイダの既定 URL。html_table 経路のみ使用。切替後の再計算は `docs/breakdown.md`（`needs_review` または行削除）。

### Fly.io（代替容易）

結合は `fly.toml` / Volume / secrets / deploy。アプリは素の OCI イメージ（Dockerfile）。方式A（Tunnel）のため Fly LB 非依存。切替: 新ホストで同イメージ＋secrets＋Tunnel トークン。

### Cloudflare（撤退経路なし・SSO）

Tunnel + Access（SSO / Service Token / MCP OAuth。MCP は開発用）。Bearer は廃止済み。安全性は **Tunnel ＋ 公開ポート閉鎖 ＋ Access** の3点セット。どれか欠けると無認証素通り。R2 バケット分離は `.agents/rules/caching.md`。

## 定常運用

- ログは JSON 1行（`ingest_summary` / `db_retry` / `http_access`）。レイテンシ切り分けは `duration_ms`（サーバー内）とクライアント往復を比較。乖離が大きいときは Tunnel/Access 側を疑う。
- 重い ingest はローカル。鮮度監視: `scripts/check-ingest-freshness.sh`。
- デプロイ: CI 成功後 `deploy.yml` が自動（手動は `workflow_dispatch`）。`/healthz` の `cache_versions` で版確認。
- cloudflared は Dockerfile で版固定。数ヶ月に一度更新。
- Fly serviceless 後は stopped になり得る → deploy ワークフローが `machine start`。
- Neon scale-to-zero: `withDbRetry` ＋プール待ち 45s。プラン変更時に再確認。
- Linux: MemberImportVisibility 回避フラグ（`AGENTS.md` / `.github/workflows/ci.yml`）。swift-nio 修正後に除去。

## Git の外にある状態

| 場所 | 内容 | 復旧 |
|---|---|---|
| Fly secrets | API キー / DB / Access / Tunnel | 再発行・`fly secrets set` |
| Neon | 全テーブル | dump または再 ingest |
| Cloudflare | Tunnel / Access / IdP / R2（icons 公開バケット・生 XBRL 私有バケット） | 本 skill で再作成。ZIP は EDINET 再取得可 |
| ローカル Mac | 手元スケジュール・`.env` | 本 skill 定期同期 |
| Fly Volume `/data` | EDINET キャッシュ（L1） | 再取得または R2 L2 |
