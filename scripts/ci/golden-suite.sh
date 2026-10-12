#!/usr/bin/env bash
# Golden suite: verify smoke/smoke_expected/.checksums.json, then run every golden
# Swift suite (smoke/*_expected.json oracles, *GoldenTests, Spec/Oracle/**).
# Any mismatch is a hard failure. Usage: scripts/ci/golden-suite.sh [--checksums-only|--print-filter]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
PY="python3 scripts/ci/cichecks.py"
case "${1:-}" in
  --print-filter) $PY golden-filter; exit 0 ;;
esac
$PY verify-checksums
[[ "${1:-}" == "--checksums-only" ]] && exit 0
filter="$($PY golden-filter)"
echo "golden filter: $filter"
swift test -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility --filter "$filter"
