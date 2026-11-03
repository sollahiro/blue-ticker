#!/usr/bin/env bash
# Self-test for scripts/ci: builds a throwaway git repo, then runs each check
# against a crafted bad diff (must fail / trigger) and a clean diff (must pass).
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q -b main . && git config user.email ci@example.invalid && git config user.name ci
mkdir -p scripts smoke/smoke_expected Sources/App SwiftTests/BlueTickerTests/Spec/Oracle docs
cp -R "$SRC" scripts/ci && rm -rf scripts/ci/__pycache__ scripts/ci/flags-baseline.tsv
TR="B""LT-42"; URL="https://""linear"".app/x/issue/1"   # assembled: never stored literally
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
manifest() { python3 - <<'PY'
import hashlib, json, pathlib
d = pathlib.Path("smoke/smoke_expected")
m = {"_note": "test"}
for p in sorted(d.glob("*.json")):
    if p.name != ".checksums.json":
        m[p.name] = hashlib.sha256(p.read_bytes()).hexdigest()
(d / ".checksums.json").write_text(json.dumps(m, indent=2) + "\n")
PY
}
printf '{"rows":[{"label":"A","value":1}]}\n' > smoke/smoke_expected/1111_2025-03-31.json
printf '{"rows":[]}\n' > smoke/breakdown_geography_expected.json
printf 'import Testing\n@Suite struct XGoldenTests {}\n' > SwiftTests/BlueTickerTests/XGoldenTests.swift
cat > Sources/App/Old.swift <<'S'
let rows = try await Company.query(on: db).all()
let old = coName.contains("トヨタ")
// see TRACKER
S
sed -i "s|TRACKER|$TR|" Sources/App/Old.swift
printf 'let app = 1\n' > Sources/App/Routes.swift
manifest
git add -A && git commit -qm base
BASE=$(git rev-parse HEAD)

pass=0; fail=0
expect() { # expect <0|1> <name> <cmd...>
  local want=$1 name=$2; shift 2
  out="$("$@" 2>&1)"; rc=$?; [[ $rc -ne 0 ]] && rc=1
  if [[ $rc == "$want" ]]; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want)"; echo "$out" | sed 's/^/     /'; fi
}
expect_out() { # expect_out <regex> <name> <cmd...>
  local re=$1 name=$2; shift 2
  out="$("$@" 2>&1)"
  if grep -qE "$re" <<<"$out"; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (no /$re/)"; echo "$out" | sed 's/^/     /'; fi
}
branch() { git checkout -q -B "$1" "$BASE"; }
F="scripts/ci/flags.sh --base $BASE --head HEAD"
G="scripts/ci/golden-rules.sh --base $BASE --head HEAD"

# ---- baseline bootstrap
branch bootstrap
scripts/ci/flags.sh --baseline >/dev/null && git add -A && git commit -qm "add baseline"
expect 0 "flags: bootstrap baseline equal to base occurrences passes" $F
echo "full-table-all	x	deadbeefdeadbeef" >> scripts/ci/flags-baseline.tsv && git commit -qam "pad baseline"
expect 1 "flags: bootstrap baseline with extra entry fails" $F
git checkout -q bootstrap~1; BL=$(git rev-parse HEAD)

# baseline growth after bootstrap
git checkout -q -B grow "$BL"
echo "issuer-contains	y	0123456789abcdef" >> scripts/ci/flags-baseline.tsv && git commit -qam "grow"
expect 1 "flags: adding a baseline line fails" scripts/ci/flags.sh --base "$BL" --head HEAD
git checkout -q -B shrink "$BL"
sed -i '/tracker-ref/d' scripts/ci/flags-baseline.tsv && git commit -qam "shrink"
expect 0 "flags: removing baseline lines passes" scripts/ci/flags.sh --base "$BL" --head HEAD
git checkout -q -B moved "$BL"
git mv Sources/App/Old.swift Sources/App/Moved.swift && sed -i 's/^let/    let/' Sources/App/Moved.swift && git commit -qam "move + reindent"
expect 0 "flags: moved/re-indented baselined lines pass" scripts/ci/flags.sh --base "$BL" --head HEAD

# ---- flags: bad diffs
for case in \
  'issuer-name|if company.coName.contains("野村") { return true }' \
  'issuer-code|if secCode.hasPrefix("8604") { return }' \
  'issuer-array|let hit = ["7203", "8604"].contains(code)' \
  'issuer-py|if "トヨタ" in filer_name: pass' \
  'all-oneline|let xs = try await Company.query(on: db).all()' \
  'all-chain|let xs = try await Company.query(on: db)\n    .field(\\.$id)\n    .all()' \
  "tracker-code|// fixes $TR" \
  "tracker-url|// $URL"; do
  name=${case%%|*}; line=${case#*|}
  git checkout -q -B "bad-$name" "$BL"
  printf "$line\n" > Sources/App/New.swift && git add -A && git commit -qm "add $name"
  expect 1 "flags: bad diff $name fails" scripts/ci/flags.sh --base "$BL" --head HEAD
done
git checkout -q -B bad-doc "$BL"
mkdir -p docs && echo "see $TR" > docs/notes.md && git add -A && git commit -qm "doc"
expect 1 "flags: tracker id in docs fails" scripts/ci/flags.sh --base "$BL" --head HEAD
git checkout -q -B bad-fixture "$BL"
echo "{\"ref\":\"$URL\"}" > smoke/fixture.json && git add -A && git commit -qm "fixture"
expect 1 "flags: tracker url in a fixture fails" scripts/ci/flags.sh --base "$BL" --head HEAD
git checkout -q -B bad-msg "$BL"
mkdir -p docs && echo ok > docs/ok.md && git add -A && git commit -qm "docs: refs $TR"
expect 1 "flags: tracker id in commit message fails" scripts/ci/flags.sh --base "$BL" --head HEAD

# ---- flags: clean diff (near-misses must not trigger)
git checkout -q -B clean "$BL"
cat > Sources/App/New.swift <<'S'
let rows = try await Company.query(on: db).filter(\.$code == code).all()
let rows2 = try await Company.query(on: db)
    .filter(\.$axis == axis)
    .sort(\.$id)
    .all()
let ok = secCode.count == 5 && secCode.hasSuffix("0")
let hit = listedCodes.contains(code)
let other = name.contains("消去")
let search = stock.coName.contains(query)
let x = "BLTX-1 PLT-3"
// company.coName.contains("comment only")
S
git add -A && git commit -qm "clean change"
expect 0 "flags: clean diff passes" scripts/ci/flags.sh --base "$BL" --head HEAD

# ---- golden rules
NOTE="source: code=1111 fy_end=2025-03-31 doc_id=S100ABCD page=42 field=売上収益/A"
branch g-clean
sed -i 's/"value":1/"value":2/' smoke/smoke_expected/1111_2025-03-31.json && manifest
git add -A && git commit -qm "golden: fix A" -m "$NOTE"
expect 0 "golden: change with note + checksums passes" $G
branch g-nonote
sed -i 's/"value":1/"value":2/' smoke/smoke_expected/1111_2025-03-31.json && manifest
git add -A && git commit -qm "golden: fix A"
expect 1 "golden: change without source note fails" $G
branch g-partial
sed -i 's/"value":1/"value":2/' smoke/smoke_expected/1111_2025-03-31.json && manifest
git add -A && git commit -qm "golden" -m "source: code=1111 doc_id=S100ABCD page=4"
expect 1 "golden: incomplete source note fails" $G
branch g-nosum
sed -i 's/"value":1/"value":2/' smoke/smoke_expected/1111_2025-03-31.json
git add -A && git commit -qm "golden: fix A" -m "$NOTE"
expect 1 "golden: change without checksum update fails" $G
branch g-inline
printf 'import Testing\n// %s\n@Suite struct XGoldenTests { @Test func a() {} }\n' "$NOTE" > SwiftTests/BlueTickerTests/XGoldenTests.swift
git add -A && git commit -qm "golden test"
expect 0 "golden: inline note next to the row passes" $G
branch g-bulk
python3 -c 'import json; json.dump({"rows":[{"label":f"r{i}","value":i} for i in range(600)]}, open("smoke/smoke_expected/1111_2025-03-31.json","w"), indent=1)'
manifest; git add -A && git commit -qm "regen" -m "$NOTE"
expect 1 "golden: bulk regeneration fails" $G
expect 0 "golden: bulk regeneration allowed with approval label" env GOLDEN_BULK_APPROVED=true $G
branch g-notgolden
mkdir -p workers/feed-rss/test-fixtures && echo '{}' > workers/feed-rss/test-fixtures/a.json
git add -A && git commit -qm "rss fixture"
expect_out "no golden files touched" "golden: feed-rss test-fixtures are not golden" $G

# ---- checksums
branch c-bad
echo ' ' >> smoke/smoke_expected/1111_2025-03-31.json && git commit -qam x
expect 1 "checksums: tampered fixture fails" scripts/ci/golden-suite.sh --checksums-only
branch c-ok
expect 0 "checksums: intact fixtures pass" scripts/ci/golden-suite.sh --checksums-only

# ---- changes: job plan from the real Package.swift target graph
git checkout -q -B c-base "$BASE"
cp "$SRC/../../Package.swift" Package.swift
for d in Sources/BlueTicker Sources/BltStoreCore Sources/BltIngestCore Sources/BltIngest Sources/BltServerCore \
         Sources/BltMcpServerCore SwiftTests/BltServerCoreTests Apps/BlueTicker docs workers/x; do
  mkdir -p "$d" && echo "// seed" > "$d/Seed.swift"
done
git add -A && git commit -qm "changes base" && CB=$(git rev-parse HEAD)
C="python3 scripts/ci/cichecks.py changes --event pull_request --base $CB --head HEAD"
plan() { # plan <name> <expected "unit_tests golden macos ios" as t/f> <file>...
  local name=$1 want=$2; shift 2
  git checkout -q -B "c-$name" "$CB"
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "// $name" >> "$f"; done
  git add -A && git commit -qm "$name"
  got="$($C 2>&1 | awk -F= '/^(unit_tests|golden|macos|ios)=/ { printf "%s", substr($2,1,1) }')"
  if [[ "$got" == "$want" ]]; then pass=$((pass+1)); echo "ok   changes: $name -> $want"
  else fail=$((fail+1)); echo "FAIL changes: $name (got $got want $want)"; $C 2>&1 | sed 's/^/     /'; fi
}
#        name            unit golden macos ios
plan ios-only         ffft Apps/BlueTicker/Seed.swift
plan docs-only        ffff docs/Seed.swift README.md
plan worker-only      ffff workers/x/Seed.swift
plan server-only      tfff Sources/BltServerCore/Seed.swift
plan mcp-only         tfff Sources/BltMcpServerCore/Seed.swift
plan server-tests     tfff SwiftTests/BltServerCoreTests/Seed.swift
plan store-core       tftf Sources/BltStoreCore/Seed.swift
plan ingest-core      tftf Sources/BltIngestCore/Seed.swift
plan core             tttf Sources/BlueTicker/Seed.swift
plan golden-test      ttff SwiftTests/BlueTickerTests/XGoldenTests.swift
plan smoke-fixture    ttff smoke/breakdown_geography_expected.json
plan ci-scripts       ttff scripts/ci/golden-suite.sh
plan package          tttt Package.resolved
plan workflow         tttt .github/workflows/ci.yml
plan deploy-workflow  ffff .github/workflows/deploy.yml
plan unknown-path     tttt newdir/thing.txt
plan ios-and-store    tftt Apps/BlueTicker/Seed.swift Sources/BltStoreCore/Seed.swift
# a real-XBRL suite in another test target pulls golden-suite in for that target
git checkout -q -B c-xbrl "$CB"
printf 'struct LiveTests { func t() { SmokeCacheSupport.ensureCached("x") } }\n' > SwiftTests/BltServerCoreTests/LiveTests.swift
git add -A && git commit -qm xbrl && CX=$(git rev-parse HEAD)
git checkout -q -B c-xbrl-edit "$CX"; echo "// edit" >> Sources/BltServerCore/Seed.swift && git commit -qam edit
expect_out "^golden=true" "changes: real-XBRL suite outside BlueTickerTests -> golden" python3 scripts/ci/cichecks.py changes --event pull_request --base "$CX" --head HEAD
# push to main: diff since the last green commit, not just the pushed commit
git checkout -q -B c-push-base "$CB"
echo "// green" >> Sources/BltServerCore/Seed.swift && git commit -qam "green" && PG=$(git rev-parse HEAD)
echo "// failed ci" >> Sources/BlueTicker/Seed.swift && git commit -qam "failed" && PF=$(git rev-parse HEAD)
echo "// docs" >> docs/Seed.swift && git commit -qam "docs only"
P="env BLT_CI_LAST_GREEN_SHA=$PG python3 scripts/ci/cichecks.py changes --event push"
expect_out "^golden=true" "changes: push after a red commit still covers the red commit's paths" $P
expect_out "^macos=true" "changes: push plan includes dependents of the unverified commit" $P
git checkout -q -B c-push-docs "$PG"
echo "// docs" >> docs/Seed.swift && git commit -qam "docs only"
expect_out "^unit_tests=false" "changes: push of a docs-only commit on a green base runs nothing heavy" env BLT_CI_LAST_GREEN_SHA="$PG" python3 scripts/ci/cichecks.py changes --event push
expect_out "cannot plan" "changes: push without a green base runs every job" env BLT_CI_LAST_GREEN_SHA= python3 scripts/ci/cichecks.py changes --event push
expect_out "^unit_tests=true" "changes: push without a green base -> unit_tests" env BLT_CI_LAST_GREEN_SHA= python3 scripts/ci/cichecks.py changes --event push
expect_out "re-run" "changes: push of the green commit itself runs every job" env BLT_CI_LAST_GREEN_SHA="$(git rev-parse HEAD)" python3 scripts/ci/cichecks.py changes --event push
expect_out "not an ancestor" "changes: push with a green base that is not an ancestor runs every job" env BLT_CI_LAST_GREEN_SHA="$PF" python3 scripts/ci/cichecks.py changes --event push
expect_out "not in the checkout" "changes: push with an unknown green base runs every job" env BLT_CI_LAST_GREEN_SHA=1111111111111111111111111111111111111111 python3 scripts/ci/cichecks.py changes --event push
expect_out "^golden=true" "changes: manual run runs every job" python3 scripts/ci/cichecks.py changes --event workflow_dispatch
expect_out "cannot plan" "changes: unknown base runs every job" python3 scripts/ci/cichecks.py changes --event pull_request --base 0000000000000000000000000000000000000000 --head HEAD
git checkout -q -B c-badpkg "$CB"; echo "garbage" > Package.swift && git commit -qam badpkg
expect_out "^macos=true" "changes: unparsable Package.swift runs every job" $C

# ---- ci-gate: aggregate check
gate() { # gate <0|1> <name> <event> <json>
  expect "$1" "ci-gate: $2" env GITHUB_EVENT_NAME="$3" NEEDS_JSON="$4" python3 scripts/ci/cichecks.py ci-gate
}
needs() { # needs <plan t/f x4> <unit> <golden> <macos> <ios> [changes] [static]
  local p=$1; tf() { [[ $1 == t ]] && echo true || echo false; }
  printf '{"changes":{"result":"%s","outputs":{"unit_tests":"%s","golden":"%s","macos":"%s","ios":"%s"}},"static-checks":{"result":"%s"},"unit-tests":{"result":"%s"},"golden-suite":{"result":"%s"},"build-macos":{"result":"%s"},"ios":{"result":"%s"},"ios-packages":{"result":"%s"}}' \
    "${6:-success}" "$(tf ${p:0:1})" "$(tf ${p:1:1})" "$(tf ${p:2:1})" "$(tf ${p:3:1})" "${7:-success}" "$2" "$3" "$4" "$5" "$5"
}
gate 0 "all planned jobs pass"            pull_request "$(needs tttt success success success success)"
gate 0 "planned skips pass"               pull_request "$(needs ffft skipped skipped skipped success)"
gate 1 "a planned job failing fails"      pull_request "$(needs tttt success failure success success)"
gate 1 "a planned job skipped fails"      pull_request "$(needs tftf skipped skipped success skipped)"
gate 1 "a cancelled job fails"            pull_request "$(needs tftf success skipped cancelled skipped)"
gate 1 "changes failing fails"            pull_request "$(needs ffff skipped skipped skipped skipped failure)"
gate 1 "static-checks failing fails"      pull_request "$(needs ffff skipped skipped skipped skipped success failure)"
gate 1 "missing plan output fails"        pull_request '{"changes":{"result":"success","outputs":{}},"static-checks":{"result":"success"},"unit-tests":{"result":"skipped"},"golden-suite":{"result":"skipped"},"build-macos":{"result":"skipped"},"ios":{"result":"skipped"},"ios-packages":{"result":"skipped"}}'
gate 1 "missing job fails"                pull_request '{"changes":{"result":"success","outputs":{}}}'

echo; echo "selftest: $pass passed, $fail failed"
[[ $fail == 0 ]]
