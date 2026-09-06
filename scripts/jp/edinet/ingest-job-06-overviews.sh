#!/bin/zsh
# Job 6: 銘柄 Overview（会社1社=1行。最新有報の「事業の内容」から LLM 生成）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-06-overviews"

ingest_require_ready

if [[ -z "${OPENROUTER_OVERVIEW_API_KEY:-}" ]]; then
  echo "ERROR: OPENROUTER_OVERVIEW_API_KEY が未設定です" >&2
  exit 1
fi

LIMIT="${BLT_INGEST_OVERVIEW_LIMIT:-80}"

ingest_run ingest --stages overviews --limit "$LIMIT"

ingest_post_hooks
