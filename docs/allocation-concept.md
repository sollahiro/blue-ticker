# Allocation（配分構造の可視化）構想

**未着手**。サーバーは分解済み数値（ノード・フロー量）のみ返し、描画はクライアント（Waterfall と同型）。

## 観点（入れ替え可能）

| 観点 | 材料 |
|---|---|
| 地域別 | geography breakdown |
| 製品・事業別 | business breakdown |
| 利益構造別 | Statement PL ＋ SS（`changes_in_equity`） |
| 投資構造別 | notes（capex / dividends）＋ rd breakdown |

## 非対象（要求具体化まで設計しない）

複数観点の合成、Sankey JSON 形式の確定、REST/MCP 設計。

## 関連

`breakdown-normalization-concept.md` · `statement-normalization-concept.md` · `blt-server-roadmap.md`
