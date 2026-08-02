# Allocation（配分構造の可視化）構想

**未着手**の将来構想メモ。今回（内訳取り込み breakdown軸拡張・財務諸表注記取り込み）整備した
データを、後から「配分構造」という観点で束ねて使うための土台の記録。実装はしない。

## 目的

収益・利益・投資の配分構造をサンキー図でクライアント側が描画できる形で返す機能。
`waterfall` のウォーターフォール分解（サーバーは前年差の要因分解値を返すのみで、グラフ描画は
クライアント側）と同じ役割分担: **サーバーは分解済みの数値（ノード・フロー量）を返すだけで、
描画（レイアウト・色・インタラクション）は持たない**。

## 観点（軸）は複数・自由に入れ替え可能

固定の1軸ではなく、以下の観点を利用側が選べる設計にする（各観点の材料は下表参照）。

| 観点 | 内容 |
|---|---|
| 地域別 | 地域ごとの売上構成（geography breakdown軸を流用） |
| 製品別・事業別 | 事業セグメントごとの売上構成（business breakdown軸を流用） |
| 利益構造別 | P&L段階分解（売上高→売上原価→売上総利益→販管費[内訳]→営業利益→…→当期純利益） |
| 投資構造別 | 資金配分（設備投資・研究開発・自己株式取得・配当金等） |

## 今回整備したデータとの対応

| Allocation観点 | 材料（今回実装済み） |
|---|---|
| 地域別 | 内訳取り込み `geography` breakdown軸 |
| 製品別・事業別 | 内訳取り込み `business` breakdown軸 |
| 利益構造別 | Statement取り込み（PL本体）＋ 財務諸表注記取り込み `sga_breakdown` note_type（販管費内訳） |
| 投資構造別 | 財務諸表注記取り込み `capital_expenditures_overview`／`research_and_development`／`dividends` note_type |

`employees`／`research_and_development` breakdown軸（内訳取り込み、今回追加）は「人員配分」観点として
将来追加する余地があるが、上表には含めない（v1想定の4観点に絞る）。

## 非対象（今回のスコープ外）

- 複数観点をまたいだ合成ロジック
- サンキー図のノード/フローJSON表現形式の確定
- REST/MCPエンドポイント設計

いずれも要求が具体化してから設計する（「実際の要求がない段階で拡張機構は作らない」原則、
`AGENTS.md`「開発哲学」）。

## 関連ドキュメント

- `docs/breakdown-normalization-concept.md` — geography/business breakdown軸
- `docs/statement-normalization-concept.md` — Statement取り込み本体・財務諸表注記取り込み
- `docs/blt-server-roadmap.md` — 財務諸表注記取り込み の索引ポインタ
