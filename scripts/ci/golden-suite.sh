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
# SmokeCacheSupport.ensureCached が出す `XBRL_SOURCE <docID> <source>` を docID 単位で集計する。
# 同じ docID が複数行出たら failed > edinet > r2 > local の順で代表を決める。
awk 'BEGIN { r["local"]=1; r["r2"]=2; r["edinet"]=3; r["failed"]=4 }
     $1 == "XBRL_SOURCE" && r[$3] > r[best[$2]] { best[$2] = $3 }
     END { for (d in best) { n[best[d]]++; t++ }
           printf "XBRL sources: docs=%d local=%d r2=%d edinet=%d failed=%d\n", t, n["local"], n["r2"], n["edinet"], n["failed"]
           for (d in best) if (best[d] == "edinet") printf "  edinet fallback: %s\n", d }' "$log" \
  | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
# XBRL_TIMING <docID> <source> wait=<秒> fetch=<秒>: 実際に取得した書類の合計と最大（時間の内訳の計測用）。
awk '$1 == "XBRL_TIMING" {
       sub(/wait=/, "", $4); sub(/fetch=/, "", $5)
       n++; w += $4; f += $5; if ($5 > fm) { fm = $5; fd = $2 }; if ($4 > wm) wm = $4 }
     END { if (n) printf "XBRL fetch timing: docs=%d fetch_sum=%.0fs fetch_max=%.1fs (%s) wait_sum=%.0fs wait_max=%.1fs\n", n, f, fm, fd, w, wm }' "$log" \
  | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
failed_docs="$(awk '$1 == "XBRL_SOURCE" && $3 == "failed" { print $2 }' "$log" | sort -u)"
rm -f "$log"
if [[ -n "$failed_docs" ]]; then
  echo "::error::golden-suite: XBRL を取得できない書類があります: $(echo $failed_docs)"
  exit 1
fi
exit "$status"
