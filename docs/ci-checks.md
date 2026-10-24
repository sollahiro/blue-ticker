# CI required checks (`scripts/ci/`)

Plain scripts, runnable locally from any checkout (`python3`, `git`, `bash`; the golden
suite also needs `swift`). CI only calls them (`.github/workflows/ci.yml`). Base/head
default to `merge-base(origin/main, HEAD)..HEAD`; override with `--base/--head` or
`CI_BASE_SHA` / `CI_HEAD_SHA`.

| Job (branch protection name) | Script | Fails on |
|---|---|---|
| `golden-suite` | `scripts/ci/golden-suite.sh` | checksum mismatch or any failing golden test |
| `golden-rules` | `scripts/ci/golden-suite.sh --checksums-only` + `scripts/ci/golden-rules.sh` | golden change rules below |
| `diff-flags` | `scripts/ci/flags.sh` | new flagged occurrence, or baseline growth |
| `ci-scripts-selftest` | `scripts/ci/tests/selftest.sh` | any check misbehaving on crafted bad/clean diffs |
| `structure` | `scripts/ci/structure.sh` | never (labels + notifies only) |

`swift-macos` is not a required check. It only compiles the package on macOS
(`swift build --build-tests`, no SwiftPM `.build` cache). Tests run on Linux
(`swift-linux` and `golden-suite`).

## Golden set

- `smoke/smoke_expected/*.json` and `smoke/smoke_expected/.checksums.json`
- `smoke/breakdown_*expected.json`, `smoke/statement_notes_*_expected.json`
- `SwiftTests/BlueTickerTests/*GoldenTests.swift`
- `SwiftTests/BlueTickerTests/Spec/Oracle/**`

`workers/feed-rss/test-fixtures/` is not golden. Owner: `@sollahiro` (`.github/CODEOWNERS`).

`golden-suite.sh` checks every fixture against `.checksums.json` (no missing,
extra, or stale entries) and then runs `swift test --filter` over every suite declared
in the golden Swift files, plus every suite declared in a Swift test file that fetches real
XBRL (`SmokeCacheSupport.ensureCached`; R2 first, then EDINET). The filter comes from those
files, so a new Oracle or real-XBRL suite is picked up automatically. `swift-linux` skips the
same filter so the suites run only once and it never downloads XBRL; `swift-macos` only
builds (it runs no tests, including the iOS helper packages, which `swift-linux` covers). Print the filter with `scripts/ci/golden-suite.sh --print-filter`.

## Golden-change rules (`golden-rules.sh`)

For each golden file the PR touches (deletions skip the note rule):

1. **Source note.** Write it next to the changed row (as a comment in Swift), or in the
   message of a commit that touches the file. One block must have all five keys:
   `source: code=8604 fy_end=2025-03-31 doc_id=S100XXXX page=123 field=<field or row>`
   (`row=` works in place of `field=`, and `pdf_page=` in place of `page=`). A note in a
   commit message covers every golden file in that commit.
2. **Checksums.** If `smoke/smoke_expected/*.json` changes, `.checksums.json` must
   change in the same PR and verify. Only that directory has a checksum manifest.
3. **No bulk regeneration.** The check fails when the golden JSON files change by more than
   **400 added+removed lines** in total, or when more than **8 golden JSON files** change.
   A real fix touches a few rows of a few companies. Going past either limit means
   fixtures were regenerated wholesale, and every row would then need its own review.
   When a large change is intended, `@sollahiro` adds the label `golden-bulk-approved`
   and re-runs the job. You can tune the limits with `GOLDEN_BULK_MAX_LINES` and `GOLDEN_BULK_MAX_FILES`.

## Flags (`flags.sh`): new occurrences only, all hard fail

The check scans only added lines (with rename detection) and the commit messages in base..head:

- **issuer-contains**: matching a company by issuer name or code substring. That covers
  `contains/hasPrefix/hasSuffix/includes/startsWith/endsWith/range(of:)` and Python
  `in` with a string literal on an issuer-name receiver (`coName`, `companyName`,
  `filerName`, `issuer*`, `*_name`…), or a code-shaped literal (`"7203"`, `"72030"`,
  `"E01234"`) on a code receiver (`code`, `secCode`, `edinetCode`, `ticker`…). It also
  covers literal code lists such as `["7203","8604"].contains(code)`. Generic searches
  (`coName.contains(query)`), format checks (`secCode.hasSuffix("0")`),
  `listedCodes.contains(code)`, XBRL member names, and comments do not match.
- **full-table-all**: a Fluent chain `X.query(on:)…​.all()` with no
  `filter/limit/range/first/group/join` between them, followed across up to 12 lines. Raw SQL is not matched.
- **tracker-ref**: tracker issue ids (team prefix, dash, number) and tracker URLs, in
  any text file (code, docs, fixtures) and in commit messages.

**Baseline**: `scripts/ci/flags-baseline.tsv` lists pre-existing occurrences as
`flag, path, sha256(line)[:16]`. It stores hashes, never text, so it cannot leak tracker ids.
An added line whose hash is in the baseline (a moved or re-indented old line) passes. The baseline
**may only shrink**: any line added to it fails. The PR that creates it passes only when
it matches exactly what `scripts/ci/flags.sh --baseline --rev <base>` generates.
After you remove an occurrence, delete its row.

## Structure check (`structure.sh`)

A change counts as structural when any of these holds:

- a new top-level directory, or a new module directory directly under `Sources/`,
  `SwiftTests/`, `workers/`, `Apps/BlueTicker/` or `scripts/`
- added `Package.swift` lines that touch targets or products (`.target(`, `.testTarget(`,
  `products:` …)
- new REST routes (`v1.get("…")` and similar in `Sources/`), new skills (`id: "…"` in
  `ApiSkills.swift`, which become both REST and MCP tools), or new worker routes
- schema or migrations: `Migrations/`, `*.sql`, `schema*` files, `AsyncMigration`,
  `.schema("…")`, or `CREATE/ALTER/DROP TABLE|INDEX`
- a large move: 15 or more renames (`STRUCTURE_MOVE_MIN_FILES`)

When it triggers on a PR, the script adds the label `needs-architect` (creating it if
needed). Right after the label is newly added (never when it was already on the PR),
it POSTs `{"pr": N}` to `ARCHITECT_WEBHOOK_URL` with header
`Authorization: $ARCHITECT_WEBHOOK_AUTH`. The secret is the full header value and is sent
as-is, with no `Bearer` prefix added. The URL and key go to curl on stdin and never
reach argv or logs. If either secret is missing, the script skips the POST with a
warning and does not fail.
