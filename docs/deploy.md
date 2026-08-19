# blt-server デプロイ手順

同一 Docker イメージを Fly と self-host で使う。構成は `architecture.md`、認証方針は `api-auth.md`。

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
| `ci.yml` | macOS/Linux test・product/serviceless ガード |
| `deploy.yml` | CI 成功後の Fly 自動デプロイ（`v*` タグでは起動しない） |
| `edge-security-smoke.yml` | Access / serviceless 外形監視 |

repo secrets: `BLT_EDINET_API_KEY`（CI smoke）· `FLY_API_TOKEN` · `BLT_API_DOMAIN`。

## self-host

```bash
docker build -t blt-server .
docker run -d --name blt-server -p 8080:8080 \
  -e BLT_EDINET_API_KEY=xxxxx -e DATABASE_URL='postgres://...' \
  -v blt_data:/data blt-server
docker exec blt-server /app/blt-server sync --from 2024-01-01
docker exec blt-server /app/blt-server ingest --limit 50
```

公開するなら Cloudflare Tunnel + Access を前段に置く。

## Cloudflare Access（方式A）

安全性は **Tunnel ＋ 公開ポート閉鎖（serviceless）＋ Access** の3点。Tunnel 維持のためマシンは always-on。

1. Tunnel 作成 → Public hostname `api.<domain>` → `http://localhost:8080`
2. Access アプリ（SSO / OTP）＋ **Service Auth**（機械用 Token）を OR 同居
3. Fly secrets: `CF_ACCESS_TEAM_DOMAIN` · `CLOUDFLARE_TUNNEL_TOKEN`
4. cloudflared は Dockerfile に同梱（版固定＋sha256）。トークン未設定なら blt-server のみ
5. `fly.toml` に `[http_service]` を戻さない（直アクセス経路が開く）

### REST Service Token

```bash
curl -s "https://api.<domain>/v1/companies/7203/financials?years=1" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"
```

SSO は `Cookie: CF_Authorization=<jwt>`（`Cf-Access-Jwt-Assertion` だけでは通らない）。

レート制限はゾーン Free の短い period のみ。悪用が観測されたらプラン検討。

## MCP（Managed OAuth）

`POST /`。Managed OAuth は**パス付きホスト不可** → 専用 `mcp.<domain>`。

1. Tunnel に `mcp.<domain>` → 同 origin
2. Access アプリ（パスなし）＋ Managed OAuth ON
3. 許可 IdP（例: One-Time PIN）と redirect URI（Apps in ChatGPT 用に Access へ登録した callback、加えて `http://localhost/callback`・`http://127.0.0.1/callback` — ポートなしで登録）
4. discovery が 200、未認証 `tools/list` が 401 であることを確認

## 定期同期（ローカル）

重い ingest はローカル。スケジュール（launchd 等）はマシン固有のためリポジトリに置かない。**ジョブ編成・実行順**は `ingest-policy.md`。**limit / skip / write** は `scripts/jp/edinet/ingest.local.env`（gitignore。PR 不要）。

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

`assets/nikkei225.csv`（gitignore）: financials/filing-sections と breakdowns の business/geography は処理順の優先。employees/rd/goodwill と statements は対象母集団そのもの（未配置なら当該軸 0 件）。business/geography の対象は上場全体。

## EDINET マスタ CSV

`assets/EdinetcodeDlInfo.csv` と Neon（`master-data-upload`）を**同時更新**。Neon に行があると Neon 優先（git だけ更新するとポーリングで巻き戻る）。

## Neon E2E

1. ローカル Postgres: `BLT_TEST_POSTGRES_URL` + `PostgresIntegrationTests`（CI linux でも実行）
2. 実 Neon: `.env` を load → `blt-server sync` → `ingest --limit` → `/v1/.../financials` が 200
