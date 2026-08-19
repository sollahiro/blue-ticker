#!/bin/zsh
# Job 3: statement-notes 重い系（borrowings / lease / PPE / 政策保有等）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-03-notes-heavy"

ingest_require_ready

LIMIT="${BLT_INGEST_NOTES_LIMIT:-80}"
NOTE_TYPES="dividends,borrowings_schedule,lease_liabilities,property_plant_equipment_schedule,capital_expenditures_overview,policy_holding_securities,goodwill_and_intangibles"

ingest_run ingest --stages statement-notes --note-types "$NOTE_TYPES" --limit "$LIMIT"

ingest_post_hooks
