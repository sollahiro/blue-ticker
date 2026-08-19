#!/bin/zsh
# Job 5: financials 再組立（fin-vN・assembly_fingerprint）。正本 ingest の後に回す。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-05-financials"

ingest_require_ready

LIMIT="${BLT_INGEST_FINANCIALS_LIMIT:-80}"

ingest_run ingest --stages financials --limit "$LIMIT"

ingest_post_hooks
