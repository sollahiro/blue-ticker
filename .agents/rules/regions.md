# Region × Source

- 市場は `JP`、開示 Source は `EDINET`。Region と Source を同一概念にしない。
- 探索 cache は `tmp_cache/edinet/` に置く。取り込み運用の正本は `.agents/skills/production-ingest/SKILL.md`。探索用の一時スクリプトを書く場合は `scripts/jp/edinet/`（Git 管理しない。取り込み運用の正本にはしない）。
- 共有レイヤに Source 固有のファイル名規則を埋め込まない。
- EU / ESEF 製品トラックは中止。再配線しない。
