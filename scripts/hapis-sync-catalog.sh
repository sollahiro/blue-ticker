#!/usr/bin/env bash
# hapis/catalog.json（有報LAB を HAPIS で公開する範囲の正本）を HAPIS へ同期する。
# HAPIS の管理 API `PUT /v1/apis/yuholab/catalog` を呼ぶだけで、hapis リポジトリには依存しない。
# 既定は dry run（計画だけ表示）。--apply で書き込み、--prune でカタログから消したルートも HAPIS から消す。
# 反映後はゲートウェイの再デプロイが要る（hapis/README.md）。
#
# Usage: HAPIS_BASE_URL=https://... HAPIS_API_TOKEN=... scripts/hapis-sync-catalog.sh [--apply] [--prune]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

: "${HAPIS_BASE_URL:?HAPIS_BASE_URL is required}"
: "${HAPIS_API_TOKEN:?HAPIS_API_TOKEN is required}"

query="dry_run=1"
for arg in "$@"; do
  case "$arg" in
    --apply) query="${query/dry_run=1/}" ;;
    --prune) query="${query}&prune=1" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
query="${query#&}"

slug="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["api"]["slug"])' hapis/catalog.json)"
curl -sS --fail-with-body -X PUT \
  "${HAPIS_BASE_URL%/}/v1/apis/${slug}/catalog?${query}" \
  -H "Authorization: Bearer ${HAPIS_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @hapis/catalog.json
echo
