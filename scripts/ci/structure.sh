#!/usr/bin/env bash
# Structural-change heuristic (docs/ci-checks.md). Never fails the build.
# When structural and running on a PR (PR_NUMBER + GH_TOKEN set):
#   - adds label needs-architect
#   - only if the label was newly added: POSTs {"pr": N} to $ARCHITECT_WEBHOOK_URL with
#     "Authorization: $ARCHITECT_WEBHOOK_AUTH" (value sent as-is). Skipped with a warning
#     when either secret is absent. Never fails; secrets are never printed.
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
    echo "::warning::could not add label needs-architect (token lacks write access?); not notifying"
    exit 0
  fi
else
  echo "label needs-architect already present; not re-notifying"
  exit 0
fi
if [[ -z "${ARCHITECT_WEBHOOK_URL:-}" || -z "${ARCHITECT_WEBHOOK_AUTH:-}" ]]; then
  echo "::warning::ARCHITECT_WEBHOOK_URL / ARCHITECT_WEBHOOK_AUTH not set; skipping architect webhook"
  exit 0
fi
payload="$(python3 -c 'import json,os; print(json.dumps({"pr": int(os.environ["PR_NUMBER"])}))')"
# URL and Authorization value (sent as-is) go through a curl config on stdin so they
# never appear in argv or logs. Equivalent to:
#   curl -X POST "$ARCHITECT_WEBHOOK_URL" -H "Authorization: $ARCHITECT_WEBHOOK_AUTH" \
#     -H "Content-Type: application/json" -d '{"pr": N}'
code="$(printf 'url = "%s"\nheader = "Authorization: %s"\n' "$ARCHITECT_WEBHOOK_URL" "$ARCHITECT_WEBHOOK_AUTH" |
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -K - -X POST \
    -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || echo 000)"
if [[ "$code" =~ ^2 ]]; then
  echo "notified architect webhook (HTTP $code)"
else
  echo "::warning::architect webhook POST failed (HTTP $code); not failing the build"
fi
