#!/bin/zsh
# 推奨順に ingest ジョブ 0–6 を連続実行する。
#
# 手元: ingest.local.env（limit/skip/write）を編集してから
#   ./scripts/jp/edinet/ingest-run-cycle.local.sh
# または set -a; . ./.env; set +a のうえ直接本スクリプト。

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPTS="$REPO/scripts/jp/edinet"
source "$SCRIPTS/ingest-common.sh"

PAUSE_SEC="${BLT_INGEST_CYCLE_PAUSE_SEC:-5}"

run_job() {
  local num="$1"
  local script="$2"
  local skip_var="BLT_INGEST_SKIP_${num}"

  if [[ -n "${(P)skip_var:-}" ]]; then
    echo "=== cycle: skip job-${num} (${skip_var} set) ==="
    return 0
  fi

  echo "=== cycle: start job-${num} ==="
  "$script"
  echo "=== cycle: done job-${num} (pause ${PAUSE_SEC}s) ==="
  sleep "$PAUSE_SEC"
}

run_job 00 "$SCRIPTS/ingest-job-00-sync-foundation.sh"
run_job 01 "$SCRIPTS/ingest-job-01-statements.sh"
run_job 02 "$SCRIPTS/ingest-job-02-notes-core.sh"
run_job 03 "$SCRIPTS/ingest-job-03-notes-heavy.sh"
run_job 04 "$SCRIPTS/ingest-job-04-breakdowns.sh"
run_job 05 "$SCRIPTS/ingest-job-05-financials.sh"
run_job 06 "$SCRIPTS/ingest-job-06-overviews.sh"

echo "=== ingest-run-cycle: complete ==="
