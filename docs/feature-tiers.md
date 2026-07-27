# 機能別提供価値と課金方針（構想）

契約の正は REST。MCP は追従面。配布 Remote CLI（`ticker`）は**廃止済み**（`docs/public-api-concept.md`）。ローカル完結の開発用 CLI は対象外（`docs/architecture.md` 参照）。

## 機能表（最新）

| 機能 | プラン枠 | 課金方針（構想・gateway 実装後に有効化） | 実装状況 | 提供価値 |
|---|---|---|---|---|
| Summarize | Basic | 無料 | 実装済 | 財務諸表の数値 |
| Filing | Basic | 無料 | 実装済 | 有報のテキスト |
| Analyze | Basic | 有料 | 実装済 | 独自の分析手法に基づいた計算値 |
| Breakdown | Basic | 有料 | 実装中 | バックエンド LLM で構造化した事業別・地域別売上 |

現時点のプラン枠は **Basic のみ**（上表の全機能が Basic に属する）。

## 前提

- 課金方針は **monetize gateway 実装後に有効化する。実装前は全機能を無料で提供する**（表の「有料」は現時点では未発効）。
- **機能の課金境界**はエンドポイント・ツール単位で決める（フィールド単位のマスキングではない）。既定は面によらず同じ無料/有料だが、**面×機能の例外もありうる**（例: MCP の Analyze だけ無料、REST は有料）。例外は表または別節で明示する。
- **面の課金・メーターは分けられること**を理想とする（REST として課金できる／MCP として課金できる）。認証・識別子も面ごとに分離できる設計を優先する（詳細は認証方式選定時に確定）。例外価格も面別識別がある方が付けやすい。
- 旧称 Segment / Geography は **Breakdown** に統合（事業別・地域別）。

## Summarize / Analyze の境界

- Summarize（`GET /v1/companies/{code}/financials`・`/half-financials`、MCP `get_financial_summary`・`get_half_financial_summary`）は水準値のみ。
- Analyze（`GET /v1/companies/{code}/analysis`・`/half-analysis`、MCP `get_analysis`・`get_half_analysis`）は Summarize と同じ水準値に加え、前年差・要因分解（事業利益ウォーターフォール・ROIC/ROE分解・ネットキャッシュ/運転資本/CCC前年差）を含む。
- 実装詳細は `FinancialsYear.analysisOnlyKeys`（`Sources/BlueTicker/Models/FinancialsContract.swift`）。DBスキーマ・cache_versionは変更していない（read時の投影のみ）。

## Breakdown の境界

- REST: `GET /v1/companies/{code}/breakdown`、MCP: `get_breakdown`
- 事業別（business）/ 地域別（geography）軸ともに実装済み（日経225構成銘柄限定など制約あり。geography は2026-07-27公開）。詳細は `docs/breakdown-normalization-concept.md`

## 関連

- `docs/public-api-concept.md` — REST 本線化と公開 API 化
- `docs/breakdown-normalization-concept.md` — Breakdown（旧 Segment / Geography）正規化構想
- `docs/blt-server-roadmap.md` — Monetize Gateway 等
