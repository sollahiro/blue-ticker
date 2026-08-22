#!/usr/bin/env bash
# Feed Trend 初回出荷: Worker デプロイ → Fly origin に URL と token。
# この Worker を api.* / mcp.* の前段に置かない。
#
# 必要:
#   CLOUDFLARE_API_TOKEN または `npx wrangler login`
#   CLOUDFLARE_ACCOUNT_ID または BLT_R2_ACCOUNT_ID（同じ Cloudflare アカウント）
#   AE_SQL_TOKEN（Account Analytics:Read。未設定なら CLOUDFLARE_API_TOKEN を流用）
#   fly にログイン済み、または FLY_API_TOKEN
# 任意:
#   BLT_FEED_TREND_TOKEN（未設定なら生成して Worker と Fly に同じ値を載せる）
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

account_id="${CLOUDFLARE_ACCOUNT_ID:-${BLT_R2_ACCOUNT_ID:-}}"
ae_sql_token="${AE_SQL_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
if [[ -z "$account_id" ]]; then
  echo "CLOUDFLARE_ACCOUNT_ID または BLT_R2_ACCOUNT_ID が必要です" >&2
  exit 1
fi
if [[ -z "$ae_sql_token" ]]; then
  echo "AE_SQL_TOKEN または CLOUDFLARE_API_TOKEN が必要です（Account Analytics:Read）" >&2
  exit 1
fi

if [[ -z "${BLT_FEED_TREND_TOKEN:-}" ]]; then
  BLT_FEED_TREND_TOKEN="$(openssl rand -hex 32)"
  echo "BLT_FEED_TREND_TOKEN を生成しました（この値は表示しません）"
fi

export CLOUDFLARE_ACCOUNT_ID="$account_id"

echo "Worker をデプロイします（workers/feed-trend）"
deploy_log="$(mktemp)"
trap 'rm -f "$deploy_log"' EXIT
(
  cd workers/feed-trend
  npx --yes wrangler@4 deploy
) | tee "$deploy_log"

url="$(grep -Eo 'https://[a-zA-Z0-9._-]+\.workers\.dev' "$deploy_log" | tail -n 1 || true)"
if [[ -z "$url" ]]; then
  echo "デプロイ出力から workers.dev URL を取れませんでした" >&2
  exit 1
fi

echo "Worker secrets を載せます"
(
  cd workers/feed-trend
  printf '%s' "$BLT_FEED_TREND_TOKEN" | npx --yes wrangler@4 secret put TOKEN
  printf '%s' "$account_id" | npx --yes wrangler@4 secret put ACCOUNT_ID
  printf '%s' "$ae_sql_token" | npx --yes wrangler@4 secret put AE_SQL_TOKEN
)

echo "Fly origin に URL と token を載せます"
fly secrets set \
  BLT_FEED_TREND_URL="$url" \
  BLT_FEED_TREND_TOKEN="$BLT_FEED_TREND_TOKEN" \
  -a blt-server

echo "完了: origin は $url を向きます。GET /v1/feed/trend は空なら 200（items=[]）、未配線なら 503。"
