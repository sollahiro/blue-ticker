#!/bin/zsh
# Job 4: breakdowns（全13軸とも上場全体。225は処理順の先頭寄せのみ）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-04-breakdowns"

ingest_require_ready

LIMIT="${BLT_INGEST_BREAKDOWN_LIMIT:-50}"
# 対象軸をカンマ区切りで絞る（例: geography,product_service）。未設定なら全軸。
AXES="${BLT_INGEST_BREAKDOWN_AXES:-}"

if [[ -n "$AXES" ]]; then
  ingest_run ingest --stages breakdowns --axes "$AXES" --limit "$LIMIT"
else
  ingest_run ingest --stages breakdowns --limit "$LIMIT"
fi

ingest_post_hooks
