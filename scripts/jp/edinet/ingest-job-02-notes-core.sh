#!/bin/zsh
# Job 2: statement-notes 安定系（fin-v9 の EPS/BPS 供給源）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-02-notes-core"

ingest_require_ready

LIMIT="${BLT_INGEST_NOTES_LIMIT:-80}"
NOTE_TYPES="per_share_information,issued_shares_and_capital"

ingest_run ingest --stages statement-notes --note-types "$NOTE_TYPES" --limit "$LIMIT"

ingest_post_hooks
