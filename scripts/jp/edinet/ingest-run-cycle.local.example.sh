#!/bin/zsh
# 手元専用 ingest ラッパー（launchd / cron が呼ぶ実体）。
#
#   cp scripts/jp/edinet/ingest-run-cycle.local.example.sh \
#      scripts/jp/edinet/ingest-run-cycle.local.sh
#   cp scripts/jp/edinet/ingest.local.env.example \
#      scripts/jp/edinet/ingest.local.env
#   chmod +x scripts/jp/edinet/ingest-run-cycle.local.sh
#   ./scripts/install-launchd.sh
#
# limit / write は ingest.local.env を編集（PR 不要）。
# 実運用ラッパー（ingest-run-cycle.local.sh）は gitignore。雛形は
# scripts/jp/edinet/ingest-run-cycle.local.sh を cp して使う（caffeinate・
# job-03 日次 skip・post 1 回化を含む）。

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"

LOG="$REPO/.build/blt-launchd-cycle.log"

caffeinate -i -s -w $$ &

set -a
. ./.env
if [[ -f "$REPO/scripts/jp/edinet/ingest.local.env" ]]; then
  . "$REPO/scripts/jp/edinet/ingest.local.env"
fi
set +a

export BLT_INGEST_SKIP_POST=1
if [[ $(date +%H) -ne 0 ]]; then
  export BLT_INGEST_SKIP_03=1
else
  unset BLT_INGEST_SKIP_03
fi

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest-run-cycle 開始 (SKIP_03=${BLT_INGEST_SKIP_03:-0}) ====="
  "$REPO/scripts/jp/edinet/ingest-run-cycle.sh"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest-run-cycle 本体完了。post hooks ====="
  source "$REPO/scripts/jp/edinet/ingest-common.sh"
  unset BLT_INGEST_SKIP_POST
  ingest_require_ready
  ingest_post_hooks
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest-run-cycle 完了 ====="
} >> "$LOG" 2>&1
