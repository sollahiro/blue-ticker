#!/bin/zsh
# Job 1: statements（上場全体・通期 BS/PL/CF/SS。日経225は処理順の優先のみ）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-01-statements"

ingest_require_ready

LIMIT="${BLT_INGEST_STATEMENTS_LIMIT:-80}"

ingest_run ingest --stages statements --limit "$LIMIT"

ingest_post_hooks
