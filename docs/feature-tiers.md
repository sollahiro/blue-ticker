# 機能別提供価値と課金方針（構想）

クライアント種別（Remote CLI / MCP 等）を問わず、機能単位で提供価値と将来の課金方針を整理する。ここでの CLI は Remote CLI（サーバー API を叩くシンクライアント）を指す。ローカル完結の開発用 CLI は対象外（`docs/architecture.md` 参照）。

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

## 関連

- `docs/segment-normalization-concept.md` — Segment / Geography の構造化構想（Stage 6）
