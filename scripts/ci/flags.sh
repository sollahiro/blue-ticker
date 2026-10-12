#!/usr/bin/env bash
# Hard-fail on NEW issuer-level contains matching, full-table Fluent .all(), or
# tracker ids / tracker URLs in base..head (diff + commit messages).
# Usage: scripts/ci/flags.sh [--base SHA] [--head SHA]
#        scripts/ci/flags.sh --baseline [--rev REV]   # regenerate the allowlist (bootstrap only)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [[ "${1:-}" == "--baseline" ]]; then shift; exec python3 scripts/ci/cichecks.py baseline "$@"; fi
exec python3 scripts/ci/cichecks.py flags "$@"
