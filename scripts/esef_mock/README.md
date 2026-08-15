# ESEF / EU IFRS pipeline mock

Script-level exploration for expanding BlueTicker beyond Japan (EDINET) to EU ESEF filings (IFRS).

**Not** production ingest. Does not change Swift targets, REST/MCP, or DB schema.

## Sources

- Filings index API: https://filings.xbrl.org/docs/api
- ESMA ESEF taxonomy documentation (PDF): `esma32-60-417_esef_xbrl_taxonomy_documentation_1.0.pdf`

## JP → EU stage map

| JP (BlueTicker) | This mock |
|---|---|
| `EdinetDiscovery` / EDINET documents.json | `discover` → `GET /api/filings` |
| `EdinetAPIClient` ZIP → `PublicDoc/` | `acquire` → xBRL-JSON (+ optional report package ZIP) |
| `XBRLUtils.collectAllNumericFacts` | `collect_facts_from_xbrl_json` |
| `detectAccountingStandard` | `detect_framework` (IFRS / ESEF namespaces) |
| `fieldSetFromDuration/Instant` + `resolveItem` | `PeriodSlots` + `build_fieldset` + `resolve_summary` |
| `StatementAnalyzer` (presentation/calc) | Fixed IFRS-full concept checklist only |

## Usage

```bash
# newest NL filings
python3 scripts/esef_mock/esef_pipeline_mock.py discover --country NL --limit 5

# summary resolve for one filing (cached under tmp_cache/esef/)
python3 scripts/esef_mock/esef_pipeline_mock.py summary --country NL --limit 1

# pin by fxo_id
python3 scripts/esef_mock/esef_pipeline_mock.py summary \
  --fxo-id 7245009QH646WM76PR25-2025-12-31-ESEF-NL-0 \
  --out /tmp/esef_summary.json

# inspect ESEF report package layout
python3 scripts/esef_mock/esef_pipeline_mock.py package-tree --country NL --limit 1
```

Stdlib only (no pip). Cache lives in `tmp_cache/esef/` (gitignored pattern via `tmp_cache/`).

## Out of scope (next when productizing)

- Presentation / calculation linkbase walk (real Statement)
- Extension-concept anchoring to IFRS-full
- Segment / geography breakdown axes
- Issuer identity mapping (LEI → listing ticker)
- Swift Core port / ingest stages / Neon
