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
log="$(mktemp)"
set +e
swift test -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility --filter "$filter" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
# SmokeCacheSupport.ensureCached が出す `XBRL_SOURCE <docID> <source>` を docID 単位で集計する
#（同じ docID を複数スイートが要求しても最初の取得元だけ数える）。
awk '$1 == "XBRL_SOURCE" && !seen[$2]++ { n[$3]++; t++ }
     END { printf "XBRL sources: docs=%d local=%d r2=%d edinet=%d failed=%d\n", t, n["local"], n["r2"], n["edinet"], n["failed"] }' "$log" \
  | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
awk '$1 == "XBRL_SOURCE" && !seen[$2]++ && $3 == "edinet" { printf "  edinet fallback: %s\n", $2 }' "$log"
rm -f "$log"
exit "$status"
