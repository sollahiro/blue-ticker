#!/bin/zsh
# 単体ジョブ用ラッパー例。launchd で job ごとに plist を分けるとき用。
#
#   cp scripts/jp/edinet/ingest-job.local.example.sh \
#      scripts/jp/edinet/local/ingest-job-02-notes-core.local.sh
#   chmod +x scripts/jp/edinet/local/ingest-job-02-notes-core.local.sh
#
# 第1引数: 00 | 01 | 02 | 03 | 04 | 05 | 06（省略時 02）

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
JOB="${1:-02}"

set -a
. "$REPO/.env"
set +a

case "$JOB" in
  00) exec "$REPO/scripts/jp/edinet/ingest-job-00-sync-foundation.sh" ;;
  01) exec "$REPO/scripts/jp/edinet/ingest-job-01-statements.sh" ;;
  02) exec "$REPO/scripts/jp/edinet/ingest-job-02-notes-core.sh" ;;
  03) exec "$REPO/scripts/jp/edinet/ingest-job-03-notes-heavy.sh" ;;
  04) exec "$REPO/scripts/jp/edinet/ingest-job-04-breakdowns.sh" ;;
  05) exec "$REPO/scripts/jp/edinet/ingest-job-05-financials.sh" ;;
  06) exec "$REPO/scripts/jp/edinet/ingest-job-06-overviews.sh" ;;
  *) echo "ERROR: unknown job $JOB (use 00-06)" >&2; exit 1 ;;
esac
