#!/usr/bin/env bash
# Structural-change heuristic (docs/ci-checks.md). Never fails the build.
# When structural and running on a PR (PR_NUMBER + GH_TOKEN set):
#   - adds label needs-architect
#   - POSTs the PR number to $BLT_ARCHITECT_WEBHOOK_URL with $BLT_ARCHITECT_WEBHOOK_KEY
#     (skipped with a warning when either secret is absent). Secrets are never printed.
# Usage: scripts/ci/structure.sh [--base SHA] [--head SHA]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
result="$(python3 scripts/ci/cichecks.py structure --json "$@")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("STRUCTURAL:" if d["structural"] else "not structural"); [print("  -",r) for r in d["reasons"]]' "$result"
structural="$(python3 -c 'import json,sys; print(int(json.loads(sys.argv[1])["structural"]))' "$result")"
[[ "$structural" == 1 ]] || exit 0
if [[ -z "${PR_NUMBER:-}" || -z "${GH_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "local run (PR_NUMBER/GH_TOKEN/GITHUB_REPOSITORY unset): not labelling or notifying"
  exit 0
fi
already="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/labels" --jq '[.[].name] | index("needs-architect") != null' || echo false)"
if [[ "$already" != "true" ]]; then
  gh api -X POST "repos/$GITHUB_REPOSITORY/labels" -f name=needs-architect -f color=d93f0b \
    -f description="Structural change: architect review required" >/dev/null 2>&1 || true
  if gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/labels" -f 'labels[]=needs-architect' >/dev/null; then
    echo "added label needs-architect"
  else
    echo "::warning::could not add label needs-architect (token lacks write access?)"
  fi
else
  echo "label needs-architect already present; not re-notifying"
  exit 0
fi
if [[ -z "${BLT_ARCHITECT_WEBHOOK_URL:-}" || -z "${BLT_ARCHITECT_WEBHOOK_KEY:-}" ]]; then
  echo "::warning::BLT_ARCHITECT_WEBHOOK_URL / BLT_ARCHITECT_WEBHOOK_KEY not set; skipping architect webhook"
  exit 0
fi
payload="$(python3 -c 'import json,os,sys; print(json.dumps({"repo": os.environ["GITHUB_REPOSITORY"], "pr_number": int(os.environ["PR_NUMBER"]), "head_sha": os.environ.get("CI_HEAD_SHA",""), "reasons": json.loads(sys.argv[1])["reasons"]}, ensure_ascii=False))' "$result")"
# URL and key go through a curl config on stdin so they never appear in argv or logs.
code="$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\n' "$BLT_ARCHITECT_WEBHOOK_URL" "$BLT_ARCHITECT_WEBHOOK_KEY" |
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -K - -X POST \
    -H 'Content-Type: application/json' --data "$payload" 2>/dev/null || echo 000)"
if [[ "$code" =~ ^2 ]]; then
  echo "notified architect webhook (HTTP $code)"
else
  echo "::warning::architect webhook POST failed (HTTP $code); not failing the build"
fi
