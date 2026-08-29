# バージョン

- `blueTickerVersion`（`Constants/Version.swift`）はアプリ世代、Neon の各 Contract `cache_version` はデータ契約世代であり、独立して扱う。
- `blueTickerVersion` は `YY.M.Micro`。月が変われば `YY.M.0`、月内は Micro を 1 上げる。
- Contract 定数は抽出ロジックまたは契約の意味が変わったときだけ上げる。read 床は serving policy 変更時だけ上げる。
- LLM 行はバンプだけでは再計算しない。決定論の `xbrl_facts` / `not_applicable` は `needs_review` だけでは再計算せず、Contract バンプで再計算する。
- PR 内の必要な Contract バンプは許可するが、細かな連続バンプはマージ前に 1 つへまとめる。本番全銘柄への定着バンプとは分けて判断する。
