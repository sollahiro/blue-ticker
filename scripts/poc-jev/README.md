# TypeSafe / Jev candidate-export PoC v2 (throwaway)

This directory is a **throwaway** branch artifact. It is not a product surface.

- Does not call TypeSafe, Jev, or any LLM.
- Does not write to Neon, R2, or change `cache_version`.
- Reuses production parsers via `@testable import BlueTickerCore`.
- The only production-tree hook is a `PocJevExport` test target in `Package.swift`.

v1 (PR #446) exported `tag_classify` / `table_select` / `cell_select` for the
revenue-recognition note only. v2 adds:

- Part A audit of current-year table selection for every latest filing
  (`out/part_a_audit.json`, `out/part_a_audit.md`)
- `table_select` + `cell_select` for `segment_info` and `geography`
- pre-extraction `usable_*.jsonl` (which table is the current-year table, or `none_of_these`)
- a small Notes sample (`issued_shares_and_capital`, `lease_liabilities`, `borrowings_schedule`)

## Run

```bash
BLT_POC_JEV_RUN=1 swift test \
  -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility \
  --filter PocJevExport
```

XBRL is fetched local-cache → R2 GET (no PUT) → EDINET, into `tmp_cache/edinet/`.
Outputs also copy to `/opt/cursor/artifacts/` when that path exists.
