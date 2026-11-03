# CI checks (`scripts/ci/`)

Plain scripts, runnable locally from any checkout (`python3`, `git`, `bash`; the golden
suite also needs `swift`). CI only calls them (`.github/workflows/ci.yml`). Base/head
default to `merge-base(origin/main, HEAD)..HEAD`; override with `--base/--head` or
`CI_BASE_SHA` / `CI_HEAD_SHA`.

Branch protection requires one check, `ci-ok`. It aggregates every other job against the
plan from `changes` (see "Change-based job plan" below).

| Job | Script | Fails on |
|---|---|---|
| `ci-ok` | `scripts/ci/cichecks.py ci-gate` | a planned job not `success`; a job planned as skip that ended anything but `skipped`/`success`; `changes` or `static-checks` not `success`; any `cancelled` |
| `changes` | `scripts/ci/cichecks.py changes` | never on its own (an error plans every job) |
| `golden-suite` | `scripts/ci/golden-suite.sh` | checksum mismatch or any failing golden test |
| `static-checks` | `scripts/ci/tests/selftest.sh`, then on PRs `scripts/ci/flags.sh`, `scripts/ci/golden-suite.sh --checksums-only` + `scripts/ci/golden-rules.sh`, then the repo invariants (Package products, serviceless `fly.toml`, Worker unit tests) | any check misbehaving on crafted bad/clean diffs; new flagged occurrence or baseline growth; golden change rules below; a broken invariant |
| `unit-tests` | `swift build --build-tests` (Build step), then `swift test` (golden filter skipped) with a Postgres 16 service | the package or its tests do not compile on Linux; any non-golden test, including `PostgresIntegrationTests` and `ReadOnlyRolePostgresTests` |
| `build-macos` | `swift build --product blt-ingest` | `blt-ingest` does not compile on macOS, or its build contains Vapor / MCP modules |
| `structure` | `scripts/ci/structure.sh` | never (labels + notifies only) |

Each job has one responsibility, so a red check (or step) names what broke. `unit-tests`
compiles everything in its Build step before testing, which replaces a separate Linux build job
that compiled the same thing a second time. `golden-suite` only tests, and the short script
checks share one runner in `static-checks` (each step still runs when an earlier one fails).
`build-macos` builds only `blt-ingest`, the one product that runs on a Mac; the server and the
tests compile on Linux in `unit-tests`. It has no SwiftPM `.build` cache, because a frozen
cache entry has failed with a missing `_NumericsShims`.

## Change-based job plan (`changes`)

On a pull request, `cichecks.py changes` diffs `merge-base(base, head)..head` and decides
which of `unit_tests`, `golden`, `macos` and `ios` to run. `static-checks`, `structure` and
`ci-ok` always run. A push to `main` (or any other event) runs every job: Deploy ships the
diff since the last successful deploy, which can include commits whose own CI failed, so
`main` must always be verified in full. Print the plan locally with
`python3 scripts/ci/cichecks.py changes`.

Swift paths map through the target graph read from `Package.swift`. A change to a target
reaches every target that depends on it, directly or not:

| Change reaches | Runs |
|---|---|
| any Swift target or test target | `unit_tests` |
| a test target holding a golden or real-XBRL suite (today `BlueTickerTests`) | `golden` |
| `BltIngest` (so `BlueTickerCore`, `BltStoreCore`, `BltIngestCore`, `BltIngest`) | `macos` |

Other paths:

| Path | Runs |
|---|---|
| `Package.swift`, `Package.resolved`, `.github/workflows/ci.yml` | everything |
| `Apps/BlueTicker/` | `ios` |
| `smoke/`, `assets/`, `scripts/ci/` | `unit_tests`, `golden` |
| `docs/`, `.agents/`, `workers/`, top-level `*.md`, other workflows, deploy files (`Dockerfile`, `fly.toml` …), ops scripts | nothing beyond the always-on jobs |
| anything else | everything |

The last row is deliberate: the code lists the paths that are safe to skip, so a new
directory runs too much rather than too little. If the base cannot be read or `Package.swift`
cannot be parsed, every job runs. `scripts/ci/tests/selftest.sh` pins the plan for the
representative cases (iOS only, server only, `BltStoreCore`, `BltIngestCore`, Core, golden
fixtures, package files, unknown paths) and every `ci-gate` outcome.

`ReadOnlyRolePostgresTests` applies every migration as the owner, then serves the DB-backed
`/v1` routes with a role that only has `SELECT` and `default_transaction_read_only = on`
(the same grants as production `blt_reader`). A route that writes, runs DDL, or reads a table
the role cannot see fails it.

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
files, so a new Oracle or real-XBRL suite is picked up automatically. `unit-tests` skips the
same filter so the suites run only once and it never downloads XBRL. Print the filter with `scripts/ci/golden-suite.sh --print-filter`.

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
