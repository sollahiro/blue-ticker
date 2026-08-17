# EU / ESEF ロードマップ

**Region `EU` · Source `ESEF` の進捗・未決・次**。命名は `.agents/rules/project/regions.md`。構成は `architecture.md`。JP 全体の進捗は `blt-server-roadmap.md`。機能マトリクスは `feature-tiers.md`。Summary 組立は `financials-summary-separation.md`（JP と同じ形を目指す）。

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

## 現在地

| 項目 | 状態 |
|---|---|
| 探索モック | `scripts/eu/esef/pipeline_mock.py`（直 Summary スパイク） |
| **Meta Search** | REST preview `GET /v1/eu/companies`（skills/MCP **未掲載**）。Icon 保留 |
| **entity index** | **保留** — ESAP（European Single Access Point）一般公開（目安 **2027-07**）まで、全件マスター構築・運用はしない |
| Struct / Norm / Viz ingest | 未着手（JP/EDINET のみ） |
| identity | 当面は LEI/`identifier`・`fxo_id`・**名称の完全一致**（live）。部分一致名称は index 依存のため ESAP 後 |
| 正本経路 | 未。Spike ≠ Filing/Statement/Notes/Breakdown 組立 |

## 方針

- **REST `/v1` が契約の正**（EU 公開時も同じ）。MCP は追従。
- 製品順は **Meta → Struct → Norm → Viz**。Summary は Struct + Breakdown 経路の組立。
- Source 固有は `eu/esef` 配下に閉じ、共有は FieldSet / resolve / 配信契約 / Waterfall 計算に限る。
- JP の実装サイクル（smoke → golden → 限定投入 → 公開）を EU でも踏む。
- 公開範囲・スキーマ追加は着手前に都度確認（`workflow.md`）。
- **発行体マスター（entity index）は ESAP 公開まで保留。** それまでは filings.xbrl.org の live 完全一致（LEI / 正確な name / fxo_id）と、固定 LEI セットでの Struct 以降を優先する。`EsefEntityIndexStore` / `refreshIndex` はコード上の試作として残し、本番ジョブ化しない。

## 機能カバレッジ（Class 順）

| Class | Feature | EU | 依存・メモ |
|---|---|---|---|
| Meta | Search | REST preview | `GET /v1/eu/companies?q=`。skills/MCP 未掲載。**index 保留（ESAP まで）**。Icon 保留 |
| Meta | Icon | 保留 | — |
| Struct | Filing | 未 | 正本の一つ。セクション方針は要設計 |
| Struct | Statement | 未 | 正本。presentation/calc・拡張・anchoring |
| Struct | Statement-Notes | 未 | 正本。EU note_type を再定義 |
| Norm | Breakdown | 未 | 内訳正本。Summary 組立の入力にもなる |
| Norm | Summary | スパイクのみ | **組立ビュー**。Filing/Statement/Notes/Breakdown 後に正式配置 |
| Viz | Waterfall | 未 | Summary 行（組立結果）の投影。計算は流用可 |
| Viz | Sankey | 未（JP も未） | Breakdown + Statement 等の材料後 |
| Feed | Update | 未 | filings.xbrl.org sync |
| Feed | Status | 未 | 母集団定義後 |
| Feed | Trend / Report | — | 未実装 / 構想 |

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

## 次（すぐ）

1. Meta Search preview は **LEI / fxo_id / 名称完全一致** に寄せて契約を磨く（部分一致・全件 index は ESAP 後）
2. **Struct**: 固定 LEI smoke と Statement 境界。Filing 方針のたたき台
3. スパイク Summary は参照データに留め、正式 Summary は Filing/Statement/Notes/Breakdown 組立として設計する

## 関連

`architecture.md` · `feature-tiers.md` · `financials-summary-separation.md` · `blt-server-roadmap.md` · `scripts/eu/esef/README.md` · `.agents/rules/project/regions.md`
