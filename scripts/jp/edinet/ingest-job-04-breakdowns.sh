#!/bin/zsh
# Job 4: breakdowns（business/geography=上場、決定論指標軸=225）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-04-breakdowns"

ingest_require_ready

LIMIT="${BLT_INGEST_BREAKDOWN_LIMIT:-50}"

ingest_run ingest --stages breakdowns --limit "$LIMIT"

ingest_post_hooks
