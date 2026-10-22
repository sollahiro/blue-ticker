#!/bin/zsh
# Job 7: 取引先・関係会社（最新有報 1 件の主要な顧客・関係会社・親会社等・政策保有株式・大株主 → company_relations）
# 区分の決まらない関係会社表だけ Jev（OPENROUTER_DECISION_API_KEY。未設定なら needs_review で残す）。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$REPO/scripts/jp/edinet/ingest-common.sh"
export INGEST_JOB_NAME="job-07-relations"

ingest_require_ready

LIMIT="${BLT_INGEST_RELATIONS_LIMIT:-80}"

ingest_run ingest --stages relations --limit "$LIMIT"

ingest_post_hooks
