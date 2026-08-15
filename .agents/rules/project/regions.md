# Region × Source 命名

モノレポ内の市場と開示系は次の対応で命名する。混ぜない。

| 軸 | 値 | 意味 |
|---|---|---|
| **Region** | `JP` / `EU` | 市場・制度圏 |
| **Source** | `EDINET` / `ESEF` | 開示パッケージの取得・書式系 |

対応: **JP ↔ EU**、**EDINET ↔ ESEF**（同階層の対）。

## パス

| 用途 | JP / EDINET | EU / ESEF |
|---|---|---|
| 探索スクリプト | `scripts/jp/edinet/` | `scripts/eu/esef/` |
| ローカル cache | `tmp_cache/edinet/`（現行） | `tmp_cache/eu/esef/` |
| Core（将来の置き場） | 現行 `API/Edinet*`・`Analysis/` 等 | 追加時は `API/Esef/`・`Analysis/EU/` 等、Region/Source がパスから分かるように |

既存 JP の Swift ファイル名を一括リネームしない（公開面・履歴コスト）。EU 追加と、触るときの局所整理で揃える。

## 禁止

- Region と Source を同一語に畳む（例: ディレクトリだけ `esef` で EU を暗示し Region 軸を落とす）
- JP 専用コンテキスト名（`CurrentYearDuration` 等）を EU 経路に持ち込む
- 共有レイヤ（FieldSet / resolve / 配信契約）に Source 固有のファイル名規則を埋め込む
