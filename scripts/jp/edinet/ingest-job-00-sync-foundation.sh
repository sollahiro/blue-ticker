#!/bin/zsh
# Job 0: EDINET sync + filing-sections（R2/L1 温め・sections stale 消化）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-00-sync-foundation"

ingest_require_ready

LIMIT="${BLT_INGEST_FILING_LIMIT:-80}"

ingest_run sync
ingest_run ingest --stages filing-sections --limit "$LIMIT"

ingest_post_hooks
