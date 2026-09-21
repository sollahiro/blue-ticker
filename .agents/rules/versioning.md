# バージョン

- `blueTickerVersion`（`Constants/Version.swift`）はアプリ世代、Neon の各 Contract `cache_version` はデータ契約世代であり、独立して扱う。
- `blueTickerVersion` は `YY.M.Micro`。月が変われば `YY.M.0`、月内は Micro を 1 上げる。
- `cache_version` / `fin-vN` / `screen-vN`（2026-09-20）: **破壊的変更**だけ該当スタンプを上げ、艦隊が正しく再構築されるようにする。**細粒度・非破壊の refinement** では上げない。影響行・コードを削除または再指定し、`--codes`（または同等の範囲限定 rebuild）で直す。既存の正しい値は残す。
- 破壊的 = 旧スタンプのままでは格納行が誤りまたは比較不能になる変更（スキーマ意味の変更、計算式の反転、数値が変わるラベル再マップ、公開面の契約変更）。
- 非破壊 = 狭いバグ修正、既存の正しい値を保つフォールバック順の調整、keyset pagination / scan 形、格納意味を変えない運用ツール。抽出ロジックを触っても、既存の正しい値が旧スタンプのまま比較可能ならバンプしない。
- やってはいけない: 「念のため」バンプ、コード範囲の修正に全宇宙再 ingest を強いること。害の判定は Neon 専用キーより MCP / 公開面の真実を優先する。
- read 床は serving policy 変更時だけ上げる。
- LLM 出力だけの訂正は非破壊として `cache_version` を上げない。対象行の削除または `needs_review=true` と `--codes` 個別 ingest で更新する。現行版の clean な LLM 行は `--codes` でも skip される。
- 決定論の狭い修正も非破壊ならバンプしない。対象の `company_financials` 行などを消して `--codes` で再組立する（消さないと現行版 skip。financials に `needs_review` は無い）。既存の埋まっている値は候補順で変わらない限定フォールバック（本表タグの末尾追加など）も上げない。
- 決定論の `xbrl_facts` / `not_applicable` は `needs_review` だけでは再計算しない。艦隊再計算が必要な破壊的変更は Contract バンプ、範囲限定なら行削除。LLM の `needs_review=true` は現行版でも再試行する。
- LLM 実害は先にコード／プロンプトを変えず当該コードだけ個別 ingest して MCP×有報を突合し、直ればプロンプトは触らない。残る場合のみプロンプト／抽出を直す（決定論を触らなければバンプしない）。
- PR 内の必要な Contract バンプは許可するが、細かな連続バンプはマージ前に 1 つへまとめる。本番全銘柄への定着バンプとは分けて判断する。
