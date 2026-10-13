#!/usr/bin/env bash
# Golden-change rules: source note per touched golden file, updated checksums,
# no bulk regeneration. Usage: scripts/ci/golden-rules.sh [--base SHA] [--head SHA]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 scripts/ci/cichecks.py golden-rules "$@"
