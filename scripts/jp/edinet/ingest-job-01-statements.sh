#!/bin/zsh
# Job 1: statements（日経225・通期 BS/PL/CF/SS）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-01-statements"

ingest_require_ready

LIMIT="${BLT_INGEST_STATEMENTS_LIMIT:-80}"

ingest_run ingest --stages statements --limit "$LIMIT"

ingest_post_hooks
