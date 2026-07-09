#!/bin/zsh
# Neon 上の derived キャッシュ鮮度を確認する（launchd ingest 停止の外形監視）。
#
# 重い ingest はローカル Mac の launchd 依存のため、マシン停止・ジョブ失敗でも
# Fly の /healthz は ok のままになる。本スクリプトは DB の updated_at を見て
# 「しばらく更新されていない」を検知する。
#
# 使い方:
#   set -a; . ./.env; set +a
#   ./scripts/check-ingest-freshness.sh
#
# 環境変数:
#   DATABASE_URL（必須）
#   BLT_FRESHNESS_MAX_AGE_HOURS（既定 36。1日3回ジョブ想定で余裕を持たせる）
#   BLT_FRESHNESS_REQUIRE_SYNC（既定 1。edinet_sync_state も見る。0 で無効）
#
# 終了コード: 0=鮮度 OK / 1=古い or 行なし / 2=設定・接続エラー

set -uo pipefail

MAX_AGE_HOURS="${BLT_FRESHNESS_MAX_AGE_HOURS:-36}"
REQUIRE_SYNC="${BLT_FRESHNESS_REQUIRE_SYNC:-1}"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "ERROR: DATABASE_URL が未設定です" >&2
  exit 2
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql が必要です（brew install libpq 等）" >&2
  exit 2
fi

# 各テーブルの最新 updated_at（UTC）と、閾値超過なら stale=1。
# sync_state は REQUIRE_SYNC=0 のとき検査対象外。
row="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F '|' -c "
WITH checks AS (
  SELECT 'company_financials'::text AS name,
         (SELECT max(updated_at) FROM company_financials) AS latest
  UNION ALL
  SELECT 'company_half_financials',
         (SELECT max(updated_at) FROM company_half_financials)
  UNION ALL
  SELECT 'company_filing_sections',
         (SELECT max(updated_at) FROM company_filing_sections)
  UNION ALL
  SELECT 'edinet_sync_state',
         (SELECT max(updated_at) FROM edinet_sync_state)
),
evaluated AS (
  SELECT name,
         latest,
         CASE
           WHEN name = 'edinet_sync_state' AND ${REQUIRE_SYNC} = 0 THEN 0
           WHEN latest IS NULL THEN 1
           WHEN latest < now() - make_interval(hours => ${MAX_AGE_HOURS}) THEN 1
           ELSE 0
         END AS stale
  FROM checks
)
SELECT
  CASE WHEN bool_or(stale = 1) THEN 'STALE' ELSE 'OK' END,
  string_agg(
    name || '=' || coalesce(to_char(latest AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), 'null')
      || CASE WHEN stale = 1 THEN '(stale)' ELSE '' END,
    ',' ORDER BY name
  )
FROM evaluated;
")" || {
  echo "ERROR: psql が失敗しました（接続・権限を確認）" >&2
  exit 2
}

IFS='|' read -r STATUS DETAIL <<< "$row"

if [ -z "${STATUS:-}" ]; then
  echo "ERROR: psql の結果が空です（接続・権限を確認）" >&2
  exit 2
fi

echo "ingest_freshness status=${STATUS} max_age_hours=${MAX_AGE_HOURS} ${DETAIL}"

if [ "$STATUS" = "OK" ]; then
  exit 0
fi
exit 1
