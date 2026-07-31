#!/usr/bin/env bash
# Neon の RO 子ブランチを WRITE 親ブランチの最新状態へ reset from parent する。
#
# RO（BLT_PROD_DATABASE_URL）は WRITE の自動レプリカではなく、作成／前回 reset
# 時点のスナップショット。WRITE へ ingest したあと本スクリプトで揃える。
# 必要 Secrets: NEON_API_KEY / NEON_PROJECT_ID / NEON_RO_BRANCH_ID / NEON_WRITE_BRANCH_ID
# （AGENTS.md「Neon Secrets」参照）。

set -euo pipefail

: "${NEON_API_KEY:?NEON_API_KEY is required}"
: "${NEON_PROJECT_ID:?NEON_PROJECT_ID is required}"
: "${NEON_RO_BRANCH_ID:?NEON_RO_BRANCH_ID is required}"
: "${NEON_WRITE_BRANCH_ID:?NEON_WRITE_BRANCH_ID is required}"

url="https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches/${NEON_RO_BRANCH_ID}/restore"

curl -fsS -X POST "$url" \
  -H "Authorization: Bearer ${NEON_API_KEY}" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d "{\"source_branch_id\":\"${NEON_WRITE_BRANCH_ID}\"}"

echo
echo "neon-reset-ro-from-parent: reset ${NEON_RO_BRANCH_ID} <- ${NEON_WRITE_BRANCH_ID} (project ${NEON_PROJECT_ID})"
