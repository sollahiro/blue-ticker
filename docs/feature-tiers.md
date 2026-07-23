# 機能別提供価値と課金方針（構想）

クライアント種別（REST / MCP 等）を問わず、機能単位で提供価値と将来の課金方針を整理する。契約の正は REST。MCP は追従面。配布 Remote CLI（`ticker`）は段階廃止方針（`docs/public-api-concept.md`）。ローカル完結の開発用 CLI は対象外（`docs/architecture.md` 参照）。

| 機能 | 課金方針（構想・gateway 実装後に有効化） | 実装状況 | 提供価値 |
|---|---|---|---|
| Summarize | 無料 | 実装済 | 財務諸表の数値 |
| Filing | 無料 | 実装済 | 有報のテキスト |
| Analyze | 有料 | 実装済 | 独自の分析手法に基づいた計算値 |
| Segment | 有料 | 構想中 | サーバーサイドの LLM で構造化した事業別売上 |
| Geography | 有料 | 構想中 | サーバーサイドの LLM で構造化した地域別売上 |

## 前提

- 課金方針は **monetize gateway 実装後に有効化する。実装前は全機能を無料で提供する**（表の「有料」は現時点では未発効）。
- 課金要否はクライアント（Remote CLI / MCP 等）非依存。同一機能はクライアントによらず同一方針。
- 課金境界は **呼び出すエンドポイント/ツール単位**で決める（フィールド単位のマスキングではない）。

## Summarize / Analyze の境界

- Summarize（`GET /v1/companies/{code}/financials`・`/half-financials`、MCP `get_financial_summary`・`get_half_financial_summary`）は水準値のみ（`ticker summarize` の表示項目と同じ）。
- Analyze（`GET /v1/companies/{code}/analysis`・`/half-analysis`、MCP `get_analysis`・`get_half_analysis`）は Summarize と同じ水準値に加え、前年差・要因分解（事業利益ウォーターフォール・ROIC/ROE分解・ネットキャッシュ/運転資本/CCC前年差）を含む（`ticker analyze` と同じ内容）。
- 実装詳細は `FinancialsYear.analysisOnlyKeys`（`Sources/BlueTicker/Models/FinancialsContract.swift`）。DBスキーマ・cache_versionは変更していない（read時の投影のみ）。

## 関連

- `docs/breakdown-normalization-concept.md` — Segment / Geography の構造化構想（Stage 6）
