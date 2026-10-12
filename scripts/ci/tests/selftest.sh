#!/usr/bin/env bash
# Self-test for scripts/ci: builds a throwaway git repo, then runs each check
# against a crafted bad diff (must fail / trigger) and a clean diff (must pass).
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q -b main . && git config user.email ci@example.invalid && git config user.name ci
mkdir -p scripts smoke/smoke_expected Sources/App SwiftTests/BlueTickerTests/Spec/Oracle docs
cp -R "$SRC" scripts/ci && rm -rf scripts/ci/__pycache__
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
S="scripts/ci/structure.sh --base $BASE --head HEAD"

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

# ---- structure
for case in \
  'toplevel|mkdir -p newtop && echo x > newtop/a.txt' \
  'module|mkdir -p Sources/NewModule && echo x > Sources/NewModule/a.swift' \
  'package|echo ".target(name: \"X\")," > Package.swift' \
  'route|echo "    v1.get(\"companies\", \":code\", \"new\") { req in }" >> Sources/App/Routes.swift' \
  'migration|mkdir -p Sources/App/Migrations && echo "struct M: AsyncMigration {}" > Sources/App/Migrations/M.swift'; do
  name=${case%%|*}; cmdline=${case#*|}
  branch "s-$name"; eval "$cmdline"; git add -A && git commit -qm "$name"
  expect_out "^STRUCTURAL" "structure: $name triggers" $S
done
branch s-move
mkdir -p Sources/Many && for i in $(seq 1 16); do echo "let v$i = $i // unique $i" > Sources/Many/f$i.swift; done
git add -A && git commit -qm many && BM=$(git rev-parse HEAD)
git mv Sources/Many Sources/Moved && git commit -qm move
expect_out "large file move" "structure: large move triggers" scripts/ci/structure.sh --base "$BM" --head HEAD
branch s-clean
echo "let app = 2" > Sources/App/Routes.swift && git commit -qam tweak
expect_out "^not structural" "structure: small edit is not structural" $S
expect_out "not labelling" "structure: structural without PR env does not call GitHub" bash -c "git checkout -q s-module && $S"

echo; echo "selftest: $pass passed, $fail failed"
[[ $fail == 0 ]]
