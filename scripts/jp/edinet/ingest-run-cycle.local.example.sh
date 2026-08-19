#!/bin/zsh
# 手元専用 ingest ラッパー（launchd / cron が呼ぶ実体）。
#
#   cp scripts/jp/edinet/ingest-run-cycle.local.example.sh \
#      scripts/jp/edinet/ingest-run-cycle.local.sh
#   cp scripts/jp/edinet/ingest.local.env.example \
#      scripts/jp/edinet/ingest.local.env
#   chmod +x scripts/jp/edinet/ingest-run-cycle.local.sh
#
# limit / skip / write は ingest.local.env を編集（PR 不要）。

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"

set -a
. ./.env
set +a

exec "$REPO/scripts/jp/edinet/ingest-run-cycle.sh"
