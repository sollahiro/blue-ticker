# EU / ESEF ロードマップ

**Region `EU` · Source `ESEF` の方針・フェーズ・未決**。命名は `.agents/rules/regions.md`。構成は `architecture.md`。JP の方針は `blt-server-roadmap.md`。機能マトリクスは `feature-tiers.md`。Summary 組立は `financials-summary-separation.md`（JP と同じ形を目指す）。進捗の現在地は Linear（[EU 現在地](https://linear.app/sollahiro/document/eu-現在地-844f7112eb70)）。

モノレポ前提（JP↔EU / EDINET↔ESEF）。リポジトリ分割はしない。

## Class 依存（JP と同じ）

実装・公開のわかりやすさの正は次（下は上に依存）:

```text
Meta → Struct → Norm → Viz
```

| Class | 役割 | 主な Feature |
|---|---|---|
| **Meta** | 誰の・どの書類か | Search, Icon |
| **Struct** | 開示の構造化（正本） | Filing, Statement, Statement-Notes |
| **Norm** | 正本からの正規化・組立 | Breakdown（内訳正本）, **Summary（組立スナップショット）** |
| **Viz** | 正規化値の分解・可視化 | Waterfall, Sankey |

**Summary の位置（重要）**: 独立の XBRL→Summary 本流ではない。JP と同じく次の経路から組む:

```text
Statement / Statement-Notes / Breakdown
                    ↓
            company_financials（組立）
                    ↓
              Summary / Waterfall
```

- Statement・Notes・Breakdown は正本 API としても直接公開。
- Summary は水準値投影。Waterfall は同行走査の分析投影（`feature-tiers.md`）。
- **Feed**（Trend / Update / Status / Report）は縦依存の外。Meta〜Norm の母集団ができた段で足す。

探索モックの「直 Summary」は **技術スパイク**（ESEF 事実が取れることの実証）であり、製品の正本経路ではない。

進捗・次アクションの現在地は Linear Team `blue-ticker`（[EU 現在地](https://linear.app/sollahiro/document/eu-現在地-844f7112eb70)）。本ファイルは方針・フェーズ定義・非ゴール・未決。

## 方針

- **REST `/v1` が契約の正**（EU 公開時も同じ）。MCP は追従。
- 製品順は **Meta → Struct → Norm → Viz**。Summary は Struct + Breakdown 経路の組立。
- Source 固有は `eu/esef` 配下に閉じ、共有は FieldSet / resolve / 配信契約 / Waterfall 計算に限る。
- JP の実装サイクル（smoke → golden → 限定投入 → 公開）を EU でも踏む。
- 公開範囲・スキーマ追加は着手前に都度確認（`AGENTS.md`）。
- **発行体マスター（entity index）は ESAP 公開まで保留。** それまでは filings.xbrl.org の live 完全一致（LEI / 正確な name / fxo_id）と、固定 LEI セットでの Struct 以降を優先する。`EsefEntityIndexStore` / `refreshIndex` はコード上の試作として残し、本番ジョブ化しない。

## 機能カバレッジ（Class 順）

Feature 一覧の正本は `feature-tiers.md`。ここは EU 固有の方針のみ。進捗は Linear（[EU 現在地](https://linear.app/sollahiro/document/eu-現在地-844f7112eb70)）。

| Class | Feature | EU 固有の方針 |
|---|---|---|
| Meta | Search | identity は LEI / `identifier` / `fxo_id` / 名称の完全一致。部分一致・全件 index は ESAP 後 |
| Meta | Icon | 当面保留 |
| Struct | Filing | セクション方針は要設計（未決） |
| Struct | Statement | presentation/calc・拡張・anchoring |
| Struct | Statement-Notes | EU note_type を再定義（JP と無理に共通化しない） |
| Norm | Breakdown | 内訳正本。Summary 組立の入力にもなる |
| Norm | Summary | **組立ビュー**。Filing/Statement/Notes/Breakdown 後に正式配置。直 extract は正にしない |
| Viz | Waterfall | Summary 行（組立結果）の投影。計算は流用可 |
| Viz | Sankey | Breakdown + Statement 等の材料後。要求具体化まで設計しない |
| Feed | Update / Status | Meta〜Norm の母集団ができた段で足す |
| Feed | Trend / Report | 構想。Report は本来クライアント責務 |

## フェーズ（Class 依存に沿う）

| # | Class 焦点 | 成果 | 書き込み |
|---|---|---|---|
| 0 | （スパイク） | ESEF 事実取得の実証（直 Summary・完了寄り） | ローカル |
| 1 | Meta | Search 契約の磨き（LEI/fxo_id/exact name）。**entity index 本番化は ESAP 後** | ローカル |
| 2 | Struct | Filing 方針 + Statement。smoke/golden 固定 LEI | ローカル |
| 3 | Struct | Statement-Notes（EU note_type） | ローカル |
| 4 | Norm | Breakdown。続けて **正本→Summary 組立**（直 extract を正にしない） | ローカル→使い捨て |
| 5 | Viz | Waterfall（組立 Summary の投影）。Sankey は要求具体化後 | 同上 |
| 6 | Feed | Update / Status | 同上 |
| 7 | 配信 | REST/MCP に Region/Source（要確認） | 公開は都度確認 |
| 8 | 母集団拡大 | 選定ユニバース → 定着後バンプ | 本番 write は明示時のみ |

Struct / Breakdown 正本が無い段階で Summary を本番公開しない。スパイクはフェーズ 2–4 の設計入力に使い、製品の正本経路にはしない。

## 非ゴール（当面）

- 別リポジトリ化 / JP `Edinet*` 一括リネーム
- 直 XBRL→Summary を EU の正本経路にする（スパイクの固定化）
- JP と同一 note_type / 有報セクション ID の無理な共通化
- オンデマンドライブパースを serving に載せる
- Meta/Struct を空にしたまま Norm/Viz だけ公開
- **ESAP 一般公開前に entity index の全件取得ジョブ・本番マスター運用を始めること**

## 未決

| 項目 | 論点 |
|---|---|
| identity（Meta） | LEI 主キーでよいか。ティッカー併記は ESAP 後に再検討 |
| entity index / マスター | **ESAP（目安 2027-07）まで保留。** ソースを ESAP にするか filings.xbrl.org 継続かもその時点で決める |
| 母集団 | 当面は固定 LEI（smoke）。全 ESEF / 指数は ESAP・index 後 |
| DB | `source` 列共用か Source 別テーブルか |
| cache_version | JP 共有床か Region/Source 別か |
| 通貨・単位 | 配信での明示・正規化 |
| Filing | セクション切るか全文+アンカーか |
| 言語 | 多言語パッケージの優先・保存 |
| Summary 組立 | JP の `FinancialsContract` / resolver をどこまで共有するか |

## 関連

`architecture.md` · `feature-tiers.md` · `financials-summary-separation.md` · `blt-server-roadmap.md` · `scripts/eu/esef/README.md` · `.agents/rules/regions.md`
