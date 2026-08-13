# 機能別提供価値と課金方針（構想）

契約の正は REST。MCP は追従面。配布 `ticker` は廃止。

## 機能表

| 層 | 機能 | 課金（構想） | 実装 | 価値 |
|---|---|---|---|---|
| 構造化 | Filing | 無料 | 済 | 有報テキスト |
| 構造化 | Statement | 無料 | 済（日経225） | BS/PL/CF/SS 全項目 |
| 構造化 | Note | 無料 | 済（日経225） | 注記構造化 |
| 正規化 | Summary | 無料 | 済 | 財務水準値 |
| 正規化 | Breakdown | 有料 | 済（日経225） | 事業・地域内訳 |
| 視覚化 | Waterfall | 有料 | 済 | 要因分解 |
| 視覚化 | Allocation（仮称） | 有料 | 未 | 配分構造（Sankey） |

プラン枠は当面 Basic のみ。有料列は **gateway 実装後に有効化**（それまで全無料）。

## 前提

- 課金境界はエンドポイント／ツール単位（フィールドマスキングではない）。面×機能の例外は明示する。
- 面別メーター（REST / MCP）を理想とする。
- 構造化層は無料、正規化以降（Summary 除く）は有料が基本方針。

## 境界

- **Summary** = 水準値のみ。**Waterfall** = 前年差・要因分解込み（同じ `company_financials` 行の投影）。
- **Breakdown**: `?axis=business|geography`（詳細は `breakdown-normalization-concept.md`）。
- **Statement / Note**: 別エンドポイント。統合するかは未決（形状・コスト差で分離継続もあり）。
- **Allocation**: `allocation-concept.md`。Breakdown の立体化はスコープ外。

正本分離のデータフロー構想: `docs/financials-summary-separation-concept.md`。

## 関連

`public-api-concept.md` · `breakdown-normalization-concept.md` · `statement-normalization-concept.md` · `allocation-concept.md` · `blt-server-roadmap.md`
