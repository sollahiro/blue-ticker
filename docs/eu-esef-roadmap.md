# EU / ESEF ロードマップ

**Region `EU` · Source `ESEF` の進捗・未決・次**。命名は `.agents/rules/project/regions.md`。構成は `architecture.md`。JP 全体の進捗は `blt-server-roadmap.md`。機能・課金は `feature-tiers.md`。

モノレポ前提（JP↔EU / EDINET↔ESEF）。リポジトリ分割はしない。

## Class 依存（JP と同じ）

実装・公開のわかりやすさの正は次の依存（下は上に依存）:

```text
Meta → Struct → Norm → Viz
```

| Class | 役割 | 主な Feature |
|---|---|---|
| **Meta** | 誰の・どの書類か | Search, Icon |
| **Struct** | 開示の構造化 | Filing, Statement, Statement-Notes |
| **Norm** | 横断比較可能な正規化 | Summary, Breakdown |
| **Viz** | 正規化値の分解・可視化 | Waterfall, Sankey/Allocation |

**Feed**（Trend / Update / Status / Report）は製品・運用面。上記の縦依存には乗せず、Meta〜Norm の母集団ができた段で足す。

探索モックが Summary から入っているのは **技術スパイク**（ESEF 事実が取れることの実証）であり、製品ロードマップの順序を Meta より前に置く意味ではない。

## 現在地

| 項目 | 状態 |
|---|---|
| 探索モック | `scripts/eu/esef/pipeline_mock.py`（filings.xbrl.org → xBRL-JSON → IFRS-full summary） |
| Swift Core / ingest / REST / MCP | 未着手（JP/EDINET のみ） |
| identity（Meta） | LEI + `fxo_id` をモックで使用。上場ティッカー対応なし |
| 実測 | Atlas Copco 等で summary 4年突合済み（Norm スパイク） |

## 方針

- **REST `/v1` が契約の正**（EU 公開時も同じ）。MCP は追従。
- 製品順は **Meta → Struct → Norm → Viz**（JP と同じ）。スパイク結果は下位 Class の設計入力に使う。
- Source 固有（取得・コンテキスト・タグ定数・パッケージ）は `eu/esef` 配下に閉じ、共有は FieldSet / resolve / 配信契約 / Waterfall 計算に限る。
- JP の実装サイクル（smoke → golden → 限定投入 → 公開）を EU でも踏む。母集団定義は別途（下記「未決」）。
- 公開範囲・スキーマ追加は着手前に都度確認（`workflow.md`）。

## 機能カバレッジ（Class 順）

| Class | Feature | EU | 依存・メモ |
|---|---|---|---|
| Meta | Search | 未 | identity（LEI / 表示名 / 書類ID / 任意ティッカー）。配信パスの前提 |
| Meta | Icon | 未 | URL 取得経路は ESEF 向けに別。favicon 層のみ流用可 |
| Struct | Filing | 未 | セクション体系が EDINET と非対応。要設計 |
| Struct | Statement | 未 | presentation/calc。拡張 taxonomy・anchoring |
| Struct | Statement-Notes | 未 | note_type を EU 向けに再定義 |
| Norm | Summary | スパイク済 | モック実証。Struct 本流のあとに Core 正規配置 |
| Norm | Breakdown | 未 | ESEF dimension / セグメント。Statement 後が自然 |
| Viz | Waterfall | 未 | Summary（Norm）が埋まれば計算は流用可 |
| Viz | Sankey / Allocation | 未（JP も未） | Breakdown + Statement 等の材料後 |
| Feed | Update | 未 | filings.xbrl.org sync（Meta/Struct の母集団と併走可） |
| Feed | Status | 未 | 母集団定義後。集計型は流用 |
| Feed | Trend | — | 地域非依存・未実装 |
| Feed | Report | — | 構想。Struct/Norm の根拠が揃ってから |

## フェーズ（Class 依存に沿う）

バンプは EU 用 cache_version 方針が決まってから（未決）。

| # | Class 焦点 | 成果 | 書き込み |
|---|---|---|---|
| 0 | （スパイク） | script で ESEF 事実・Summary 形を実証（完了寄り） | ローカル |
| 1 | Meta | identity マスター案・Search 契約（要確認）。`API/Esef` 発見/取得 | ローカル |
| 2 | Struct | Filing 方針決定 + Statement（linkbase）。smoke/golden 固定 LEI | ローカル |
| 3 | Struct | Statement-Notes（EU note_type） | ローカル |
| 4 | Norm | Summary resolve を Core へ。続けて Breakdown | ローカル→使い捨て |
| 5 | Viz | Waterfall（Summary 投影）。Allocation は要求具体化後 | 同上 |
| 6 | Feed | Update / Status（母集団に対する鮮度・カバレッジ） | 同上 |
| 7 | 配信 | REST/MCP に Region/Source を載せる契約（要確認） | 公開は都度確認 |
| 8 | 母集団拡大 | 選定ユニバースの全件 → 定着後バンプ | 本番 write は明示時のみ |

Struct が固まる前に Norm を本番公開しない（JP と同様、構造化の上に正規化が乗る）。スパイクの Summary はフェーズ 4 の入力であり、フェーズ 1–3 を飛ばす根拠にはしない。

## 非ゴール（当面）

- 別リポジトリ化
- JP の `Edinet*` 一括リネーム
- ESEF の全拡張概念の完全正規化（anchoring 未決のまま全域カバー）
- JP と同一の note_type / 有報セクション ID の無理な共通化
- オンデマンドライブパースを serving に載せる（JP と同様 DB read のみ）
- Norm/Viz だけ先に公開して Meta/Struct を空にする構成

## 未決

| 項目 | 論点 |
|---|---|
| identity（Meta） | パスを `companies/{code}` のままにするか、LEI 併用か、Region プレフィックスか |
| 母集団 | 全 ESEF / 指数構成 / 国フィルタ。初期は少数 LEI 固定でよい |
| DB | テーブル共用（`source` 列）か Source 別テーブルか |
| cache_version | JP と共有床か Region/Source 別か |
| 通貨・単位 | 配信でどう正規化・明示するか（モックは iso4217 のまま） |
| Filing（Struct） | ESEF 単一 iXBRL を「セクション」に切るか、全文+アンカーか |
| 言語 | 同一 `fxo_id` の多言語パッケージの優先・保存 |

## 次（すぐ）

1. **Meta**: identity / Search の配信パス案を1つに絞って確認（公開面のため着手前確認）
2. **Struct**: 固定 LEI smoke 候補（国・業種・拡張の差。Atlas Copco は初期枠）と Statement の Swift 境界
3. スパイク Summary は Struct 設計の参照データとして残し、製品順では Meta/Struct の後に Norm へ正式配置

## 関連

`architecture.md` · `feature-tiers.md` · `blt-server-roadmap.md` · `scripts/eu/esef/README.md` · `.agents/rules/project/regions.md`
