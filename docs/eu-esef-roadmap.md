# EU / ESEF ロードマップ

**Region `EU` · Source `ESEF` の進捗・未決・次**。命名は `.agents/rules/project/regions.md`。構成は `architecture.md`。JP 全体の進捗は `blt-server-roadmap.md`。機能・課金は `feature-tiers.md`。

モノレポ前提（JP↔EU / EDINET↔ESEF）。リポジトリ分割はしない。

## 現在地

| 項目 | 状態 |
|---|---|
| 探索モック | `scripts/eu/esef/pipeline_mock.py`（filings.xbrl.org → xBRL-JSON → IFRS-full summary） |
| Swift Core / ingest / REST / MCP | 未着手（JP/EDINET のみ） |
| identity | LEI + `fxo_id` をモックで使用。上場ティッカー対応なし |
| 実測 | Atlas Copco 等で summary 4年突合済み |

## 方針

- **REST `/v1` が契約の正**（EU 公開時も同じ）。MCP は追従。
- Source 固有（取得・コンテキスト・タグ定数・パッケージ）は `eu/esef` 配下に閉じ、共有は FieldSet / resolve / 配信契約 / Waterfall 計算に限る。
- JP の実装サイクル（smoke → golden → 限定投入 → 公開）を EU でも踏む。母集団定義は別途（下記「未決」）。
- 公開範囲・スキーマ追加は着手前に都度確認（`workflow.md`）。

## 機能カバレッジ（目標順）

既存機能表に対する EU 到達の目安。実装前の設計確認が必要な行は「要確認」。

| Class | Feature | EU 到達 | 依存・メモ |
|---|---|---|---|
| Norm | Summary | **P0** | モック実証済。Core 移植の第一候補 |
| Struct | Statement | **P0** | presentation/calc。拡張 taxonomy・anchoring |
| Viz | Waterfall | P1 | Summary 行が埋まれば計算は流用可 |
| Feed | Update | P1 | filings.xbrl.org sync（EDINET sync の対） |
| Feed | Status | P1 | 母集団定義後。集計型は流用 |
| Meta | Search | P1 | identity 設計が前提（LEI / ティッカー / 書類ID） |
| Norm | Breakdown | P2 | ESEF dimension / セグメント。JP TextBlock 経路は流用薄 |
| Struct | Filing | P2 | セクション体系が EDINET と非対応。要設計 |
| Struct | Statement-Notes | P2 | note_type セットを EU 向けに再定義 |
| Meta | Icon | P3 | URL 取得経路が別。favicon 層のみ流用 |
| Viz | Sankey / Allocation | P3 | JP 同様未実装。Breakdown+Statement 後 |
| Feed | Trend | — | 地域非依存・未実装のまま |
| Feed | Report | — | 構想。根拠コーパスが揃ってから |

## フェーズ

JP の実装サイクルに対応。バンプは EU 用 cache_version 方針が決まってから（未決）。

| # | 段階 | 成果 | 書き込み |
|---|---|---|---|
| 0 | 探索（現在） | script モック・実 filing 突合 | ローカルのみ |
| 1 | Core 骨格 | `API/Esef` 取得 + `Analysis/EU` の facts / period / summary resolve | ローカル |
| 2 | smoke / golden | 固定 LEI セット（会計・言語・拡張の次元）+ エッジ蓄積 | ローカル |
| 3 | Statement | linkbase 本表。タグ透明性維持 | ローカル |
| 4 | ingest 試作 | sync + financials（Summary）。使い捨て DB | 使い捨て |
| 5 | 配信 | REST/MCP に Region/Source を載せる契約（要確認） | 公開は都度確認 |
| 6 | Waterfall / Status / Update | Summary 依存機能 | 同上 |
| 7 | Search identity | マスター（LEI↔表示名↔任意ティッカー） | 要確認 |
| 8 | Breakdown | business/geography 相当 | 要確認 |
| 9 | Filing / Notes | EU 文書構造・注記セット | 要確認 |
| 10 | 母集団拡大 | 選定ユニバースの全件揃え → 定着後バンプ | 本番 write は明示時のみ |

## 非ゴール（当面）

- 別リポジトリ化
- JP の `Edinet*` 一括リネーム
- ESEF の全拡張概念の完全正規化（anchoring 未決のまま全域カバー）
- JP と同一の note_type / 有報セクション ID の無理な共通化
- オンデマンドライブパースを serving に載せる（JP と同様 DB read のみ）

## 未決

| 項目 | 論点 |
|---|---|
| identity | パスを `companies/{code}` のままにするか、LEI 併用か、Region プレフィックスか |
| 母集団 | 全 ESEF / 指数構成 / 国フィルタ。初期は少数 LEI 固定でよい |
| DB | テーブル共用（`source` 列）か Source 別テーブルか |
| cache_version | JP と共有床か Region/Source 別か |
| 通貨・単位 | 配信でどう正規化・明示するか（モックは iso4217 のまま） |
| Filing | ESEF 単一 iXBRL を「セクション」に切るか、全文+アンカーか |
| 言語 | 同一 `fxo_id` の多言語パッケージの優先・保存 |

## 次（すぐ）

1. 固定 LEI smoke 候補を数社選ぶ（国・業種・拡張の差が出るもの。Atlas Copco は初期枠）
2. Summary の Swift 移植境界を決める（共有 resolve vs `Analysis/EU` 完結）
3. identity / 配信パスの案を1つに絞って確認（公開面のため着手前確認）

## 関連

`architecture.md` · `feature-tiers.md` · `blt-server-roadmap.md` · `scripts/eu/esef/README.md` · `.agents/rules/project/regions.md`
