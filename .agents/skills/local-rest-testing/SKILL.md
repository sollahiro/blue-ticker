---
name: local-rest-testing
description: Test BlueTicker DB-backed REST endpoints and rebuild commands against disposable local PostgreSQL without production writes.
---

# Local DB-backed REST testing

Use this for HTTP/CLI end-to-end checks, not live EDINET ingest or production Neon operations.
Existing production-ingest skill covers those separate operations.

## Secrets

None for isolated seeded DB reads/rebuilds. Startup requires `BLT_EDINET_API_KEY`;
use an explicit dummy value only when the tested path never calls EDINET.
Actual upstream ingest requires the real `BLT_EDINET_API_KEY` and its own test setup.

## Setup

1. Build with `swift build -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility`.
2. If psql/PostgreSQL is absent, run disposable `postgres:16` with Apple `container`
   (`docs/architecture.md` / `.agents/rules/architecture.md`。手元のテスト Postgres は Docker にしない)。
   `container system start` if needed. Set `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
   to local-only values and publish an unused port on **127.0.0.1**, not all interfaces.
   Example: `container run -d --name blt-pg-test -p 127.0.0.1:<pg-port>:5432 -e POSTGRES_USER=...
   -e POSTGRES_PASSWORD=... -e POSTGRES_DB=... postgres:16`
3. Start `.build/debug/blt-server --host 127.0.0.1 --port <unused-port>` with
   `DATABASE_URL=postgres://<local-user>:<local-password>@127.0.0.1:<pg-port>/<db>?sslmode=disable`
   and the dummy `BLT_EDINET_API_KEY`. Migrations apply automatically.
4. Verify the server log reports startup and migration completion. Seed via
   `container exec -i blt-pg-test psql -v ON_ERROR_STOP=1 -U <user> -d <db>`.
   Never inherit a production DATABASE_URL; explicitly override it with loopback.
5. To test storage absence, start a second process on another port using
   `env -u DATABASE_URL BLT_EDINET_API_KEY=local-test-not-real ...`.

## Screen fixture/rebuild checks

`blt-server screen-rebuild` and `GET /v1/screen` exist on current `main` (BLT-49).

- `company_financials` requires code, response JSONB, cache_version, requested_years.
- Minimal response: schema_version=2, code/name/market/sector/currency/unit, years.
  Annual objects accept fy_end and metric fields (e.g. sales/roic). Empty `market` is
  excluded from `screen_index`.
- Read current `companyFinancialsCacheVersion` from FinancialsContract.swift; do not
  hardcode a version into a reusable test. Below-floor rows should be excluded.
- Execute `blt-server screen-rebuild` with the same explicit local DATABASE_URL
  (this is a subcommand; unknown argv falls through to the HTTP server).
  Assert both CLI summary and subsequent real HTTP response.
- Empty `screen_index` (0 rows) is HTTP 404. Filter 0 matches with a generated index
  is HTTP 200 and `items: []`.
- Seed more than 200 rows to exercise pagination and default/max query limits.
- Seed prior-first year arrays to distinguish latest-FY selection from array order.
- Screen empty/valueless/whitespace-only range bounds intentionally mean omitted filters.
- SQL seeding plus rebuild does **not** prove the live financial ingest hook, skip-path
  backfill, or their best-effort error handling. State that limitation explicitly.

Capture curl status, headers, JSON, and expected-vs-actual assertions. No recording
is needed for shell-only API checks. Stop local server processes and the Postgres
container afterward (`container stop blt-pg-test`).
