# Region × Source

- 市場・制度圏は `JP` / `EU`、開示取得・書式系は `EDINET` / `ESEF`。Region と Source を同一概念にしない。
- 探索スクリプトは `scripts/jp/edinet/` / `scripts/eu/esef/`、探索 cache は `tmp_cache/edinet/` / `tmp_cache/eu/esef/` に置く。
- EU の Core は Region / Source がパスから分かる `API/Esef/`・`Analysis/EU/` 等に置く。既存 JP は一括 rename しない。
- JP 専用コンテキスト名を EU 経路へ持ち込まない。共有レイヤに Source 固有のファイル名規則を埋め込まない。
