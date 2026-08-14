# 機能別提供価値と課金方針

契約の正は REST。MCP は追従面。ドメイン仕様は `statement.md` / `breakdown.md`。第三者公開（段階 B）は `public-api.md`。

## 機能表

| 層 | 機能 | 課金（構想） | 実装 | 価値 |
|---|---|---|---|---|
| 構造化 | Filing | 無料 | 済 | 有報テキスト |
| 構造化 | Statement | 無料 | 済（日経225） | BS/PL/CF/SS 全項目 |
| 構造化 | Note | 無料 | 済（日経225） | 注記構造化 |
| 正規化 | Summary | 無料 | 済 | 財務水準値 |
| 正規化 | Breakdown | 有料 | 済（全上場 ingest） | 事業・地域内訳 |
| 視覚化 | Waterfall | 有料 | 済 | 要因分解 |
| 視覚化 | Allocation（仮称） | 有料 | 未 | 配分構造（Sankey） |

プラン枠は当面 Basic のみ。有料列は **課金面へ x402 を入れたあと有効化**（それまで全無料）。ChatGPT 面は有効化後も全無料。

## 面

| 面 | 課金 |
|---|---|
| ChatGPT（コネクタ／ディレクトリ） | 機能表の有料列も含め **全ツール無料** |
| REST | 機能表に従う。機械課金は x402（顧客アカウントなし） |
| x402 を話せる MCP | 機能表に従う |

ウォレットの無いホスト型 MCP（ChatGPT 以外）は、有料ツールは 402 になり無料ツールだけ使える。ChatGPT 面の識別（同一 `mcp.*` 上で無料にする方法）は課金有効化時に決める。

## 前提

- 課金境界はエンドポイント／ツール単位（フィールドマスキングではない）。面×機能の例外は上表のみ（ChatGPT は全無料）。
- 顧客アカウントは持たない。機械課金は x402。
- 面別メーター（REST / MCP）を理想とする。ChatGPT 無料面はメーター対象外。
- 構造化層は無料、正規化以降（Summary 除く）は有料が基本方針。

## 境界

- **Summary** = 水準値のみ。**Waterfall** = 前年差・要因分解込み（同じ `company_financials` 行の投影）。
- **Breakdown**: `?axis=business|geography`（`breakdown.md`）。
- **Statement / Note**: 別エンドポイント。統合するかは未決（形状・コスト差で分離継続もあり）。
- **Allocation（未着手）**: サーバーは分解済み数値のみ返し描画はクライアント。観点の材料は geography / business / Statement PL+SS / notes(capex·dividends)+rd。複数観点の合成・JSON 形式・エンドポイントは要求具体化まで設計しない。Breakdown の立体化はスコープ外。

正本分離: `financials-summary-separation.md`。

## 関連

`public-api.md` · `breakdown.md` · `statement.md` · `blt-server-roadmap.md`
