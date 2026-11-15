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
2. If psql/PostgreSQL is absent, run disposable `postgres:16` with the local container
   runtime (current standard on Mac: Apple `container`; `docker run` is equivalent.
   `docs/architecture.md` / `.agents/rules/architecture.md`).
   `container system start` if needed. Set `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
   to local-only values and publish an unused port on **127.0.0.1**, not all interfaces.
   Example: `container run -d --name blt-pg-test -p 127.0.0.1:<pg-port>:5432 -e POSTGRES_USER=...
   -e POSTGRES_PASSWORD=... -e POSTGRES_DB=... postgres:16`
3. Apply the schema with `.build/debug/blt-ingest migrate` and
   `DATABASE_URL=postgres://<local-user>:<local-password>@127.0.0.1:<pg-port>/<db>?sslmode=disable`.
   `blt-server` never migrates; it only reads.
4. Start `.build/debug/blt-server --host 127.0.0.1 --port <unused-port>` with the same `DATABASE_URL`
   and the dummy `BLT_EDINET_API_KEY`. Verify the server log reports startup. Seed via
   `container exec -i blt-pg-test psql -v ON_ERROR_STOP=1 -U <user> -d <db>`.
   Never inherit a production DATABASE_URL; explicitly override it with loopback.
5. To test storage absence, start a second process on another port using
   `env -u DATABASE_URL BLT_EDINET_API_KEY=local-test-not-real ...`.

Capture curl status, headers, JSON, and expected-vs-actual assertions. No recording
is needed for shell-only API checks. Stop local server processes and the Postgres
container afterward (`container stop blt-pg-test`).
