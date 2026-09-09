# バージョン

- `blueTickerVersion`（`Constants/Version.swift`）はアプリ世代、Neon の各 Contract `cache_version` はデータ契約世代であり、独立して扱う。
- `blueTickerVersion` は `YY.M.Micro`。月が変われば `YY.M.0`、月内は Micro を 1 上げる。
- Contract 定数は抽出ロジックまたは契約の意味が変わったときだけ上げる。read 床は serving policy 変更時だけ上げる。
- LLM 出力だけの訂正は `cache_version` を上げない。対象行の削除または `needs_review=true` と `--codes` 個別 ingest で更新する。決定論ロジック変更は現行どおりバンプする（曖昧ならバンプ）。LLM 実害は先にコード／プロンプトを変えず当該コードだけ個別 ingest して MCP×有報を突合し、直ればプロンプトは触らない。残る場合のみプロンプト／抽出を直す（決定論を触らなければバンプしない）。
- 決定論の `xbrl_facts` / `not_applicable` は `needs_review` だけでは再計算せず、Contract バンプで再計算する。LLM の `needs_review=true` は現行版でも再試行する。
- PR 内の必要な Contract バンプは許可するが、細かな連続バンプはマージ前に 1 つへまとめる。本番全銘柄への定着バンプとは分けて判断する。
