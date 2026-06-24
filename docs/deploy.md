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
```

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

# 初回同期
docker exec blt-server /app/blt-server sync --from 2024-01-01
```

## 定期同期

`blt-server sync` はワンショット。定期実行は Fly スケジューラ（`fly machine run ... --schedule`）または self-host の cron / launchd で `sync`（引数なし＝前回 `synced_through` から当日まで）を回す。
