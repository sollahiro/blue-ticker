# 機能別提供価値と課金方針（構想）

契約の正は REST。MCP は追従面。配布 Remote CLI（`ticker`）は**廃止済み**（`docs/public-api-concept.md`）。ローカル完結の開発用 CLI は対象外（`docs/architecture.md` 参照）。

## 機能表（最新）

機能群を「構造化 → 正規化 → 視覚化」の3層で整理する。構造化層はEDINET由来データの構造化そのもの、正規化層は指標としての比較可能性を作る層、視覚化層は独自ロジックに基づく見せ方（Waterfall に加え Allocation・Cube を追加）。

| 層 | 機能 | プラン枠 | 課金方針（構想・gateway 実装後に有効化） | 実装状況 | 提供価値 |
|---|---|---|---|---|---|
| 構造化 | Filing | Basic | 無料 | 実装済 | 有報のテキスト |
| 構造化 | Statement | Basic | 無料 | 実装済（日経225限定） | 財務諸表（BS/PL/CF）の全項目正規化 |
| 構造化 | Note（旧 Statement Notes、名称検討中） | Basic | 無料 | 実装済（日経225限定） | 財務諸表注記の構造化 |
| 正規化 | Summary | Basic | 無料 | 実装済 | 財務諸表の数値 |
| 正規化 | Breakdown | Basic | 有料 | 実装済 | 事業別・地域別のセグメント分析 |
| 視覚化 | Waterfall | Basic | 有料 | 実装済 | 事業利益・ROIC・ROEの分解 |
| 視覚化 | Allocation（Sankey、名称検討中） | Basic | 有料 | 検討中 | 地域別・製品別・利益構造・投資構造。項目入れ替え可能な内訳 |
| 視覚化 | Cube | Basic | 有料 | iOS実装のみ | Waterfall の立体的探索UI。詳細は `docs/ios-app-concept.md`。REST/MCP での公開範囲・エンドポイント形状は未確定 |

現時点のプラン枠は **Basic のみ**（上表の全機能が Basic に属する）。

## 前提

- 課金方針は **monetize gateway 実装後に有効化する。実装前は全機能を無料で提供する**（表の「有料」は現時点では未発効）。
- **機能の課金境界**はエンドポイント・ツール単位で決める（フィールド単位のマスキングではない）。既定は面によらず同じ無料/有料だが、**面×機能の例外もありうる**（例: MCP の Waterfall だけ無料、REST は有料）。例外は表または別節で明示する。
- **面の課金・メーターは分けられること**を理想とする（REST として課金できる／MCP として課金できる）。認証・識別子も面ごとに分離できる設計を優先する（詳細は認証方式選定時に確定）。例外価格も面別識別がある方が付けやすい。
- 旧称 Segment / Geography は **Breakdown** に統合（事業別・地域別）。
- 構造化層（Filing / Statement / Note）は無料、正規化層以降（Summary を除く）は有料、という層単位の境界を基本方針とする。Summary は正規化層内の例外的な無料機能。
- 旧称 Statement Notes は表内で「Note」と仮称（名称未確定）。あわせて Tier を有料→無料に変更（構造化層は無料という方針転換に伴う）。

## Summary / Waterfall の境界

- Summary（`GET /v1/companies/{code}/financials`、MCP `get_financial_summary`）は水準値のみ。
- Waterfall（`GET /v1/companies/{code}/waterfall`、MCP `get_waterfall`）は Summary と同じ水準値に加え、前年差・要因分解（事業利益ウォーターフォール・ROIC/ROE分解・ネットキャッシュ/運転資本/CCC前年差）を含む。
- 実装詳細は `FinancialsYear.analysisOnlyKeys`（`Sources/BlueTicker/Models/FinancialsContract.swift`）。DBスキーマ・cache_versionは変更していない（read時の投影のみ）。

## Breakdown の境界

- REST: `GET /v1/companies/{code}/breakdown`、MCP: `get_breakdown`
- 事業別（business）/ 地域別（geography）軸ともに実装済み（日経225構成銘柄限定など制約あり。geography は2026-07-27公開）。詳細は `docs/breakdown-normalization-concept.md`

## Statement / Note の境界

- 本体（BS/PL/CF 全項目、statements）と注記（Note、旧 statement-notes）は**別エンドポイント・別ツール**: `GET /v1/companies/{code}/statement`（MCP `get_statement`）/ `GET /v1/companies/{code}/statement/notes`（MCP `get_statement_notes`）。エンドポイント/ツール名自体は現状変更していない（表示名の Note 化のみ）。
- **要検討**: 分離当初の理由は「本体無料・注記有料のティア分け」だったが、今回 Note を無料へ変更したため、この理由は成立しなくなった。エンドポイントを分けたまま維持するか、統合するかは未決定（データ形状・取得コストの違いなど他の理由で分離を続ける選択肢もある）。
- 本体（`GET /v1/companies/{code}/statement`・`get_statement`）は DB/ingest/REST/MCP まで実装済み（2026-07-29、対象は日経225限定）。Note（statement-notes）も DB/ingest/REST/MCP まで実装済み（2026-08-02、対象は日経225限定）。詳細は `docs/statement-normalization-concept.md`

## Cube / Allocation（視覚化層の拡張）

- Cube は **Waterfall の派生**。Breakdown の立体化はスコープ外とし、Allocation（Sankey）側の iOS 拡張候補として別扱いにする。
- Sankey（Allocation）は表内の名称は仮称（名称検討中）。Waterfall（旧 Analyze）は名称確定済み。
- Cube の REST/MCP 公開範囲・エンドポイント形状（`/cube` 等）は未確定。詳細検討は `docs/ios-app-concept.md`

## 関連

- `docs/public-api-concept.md` — REST 本線化と公開 API 化
- `docs/breakdown-normalization-concept.md` — Breakdown（旧 Segment / Geography）正規化構想
- `docs/statement-normalization-concept.md` — Statement（BS/PL/CF 完全正規化）構想
- `docs/ios-app-concept.md` — Cube（立体的財務分析エクスプローラ）構想
- `docs/blt-server-roadmap.md` — Monetize Gateway 等
