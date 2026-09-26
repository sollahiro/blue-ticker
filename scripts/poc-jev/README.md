# TypeSafe / Jev candidate-export PoC (throwaway)

This directory is a **throwaway** branch artifact. It is not a product surface.

- Does not call TypeSafe, Jev, or any LLM.
- Does not write to Neon, R2, or change `cache_version`.
- Reuses production parsers (`XBRLUtils.collectAllNumericFacts`, `loadCalculationComponents`, `loadLabelsByTag`, `BreakdownExtractor.extractSegmentInfo` / `extractRevenueRecognitionInfo` / `llmUserPrompt` / `table.period`) via `@testable import BlueTickerCore`.
- The only production-tree hook is a `PocJevExport` test target in `Package.swift` so internal parsers can be called without making them public.

## Run

```bash
BLT_POC_JEV_RUN=1 swift test \
  -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility \
  --filter PocJevExport
```

XBRL is fetched local-cache → R2 GET (no PUT) → EDINET, into `tmp_cache/edinet/`.

Neon read-only dumps live in `scripts/poc-jev/snapshots/` (not `data/`, which is gitignored).
Outputs: `scripts/poc-jev/out/*.jsonl` (also copied to `/opt/cursor/artifacts/` when that path exists).
