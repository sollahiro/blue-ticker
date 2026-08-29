# EU / ESEF

Region `EU` · Source `ESEF` の探索コード。命名規約は `.agents/rules/regions.md`。

対となる JP / EDINET 実装の正本は Swift（`Sources/BlueTicker/`）。ポインタは `scripts/jp/edinet/`。

## pipeline_mock.py

filings.xbrl.org → xBRL-JSON → IFRS-full summary resolve（stdlib only）。

```bash
python3 scripts/eu/esef/pipeline_mock.py self-check
python3 scripts/eu/esef/pipeline_mock.py discover --country NL --limit 5
python3 scripts/eu/esef/pipeline_mock.py summary --country SE --lei 213800T8PC8Q4FYJZR07
python3 scripts/eu/esef/pipeline_mock.py package-tree --country NL --limit 1
```

Cache: `tmp_cache/eu/esef/`（gitignored）。
