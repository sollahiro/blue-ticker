# financials（Summary）と正本の分離構想

`company_financials`（公開面の呼称は Summary、`docs/feature-tiers.md`）が担ってきた
「XBRL 抽出のなんでも屋」を、正本（statement / notes / breakdown）とそこから組み立てる
ビュー（Summary / Waterfall / 将来 Sankey）に分離する構想。

## 用語

| 呼び名 | 意味 |
|---|---|
| **financials** | 実装・Neon 名（`FinancialsResponse` / テーブル `company_financials` /
  `companyFinancialsCacheVersion` / REST `.../financials`）。リネームしていない |
| **Summary** | 公開面の呼称（MCP `get_financial_summary`）。水準値の投影 |
| **Waterfall** | 同じ `company_financials` 行の分析投影（MCP `get_waterfall`） |

Neon に Summary 専用テーブルはない。**1行 JSONB（`response`）に水準値と分析用フィールドが
同居**し、Summary / Waterfall は read 時投影で分かれる（`summaryJsonObject` /
`analysisJsonObject`）。

## データフロー（合意）

**いま**

```
XBRL →（IndividualAnalyzer / Extractors）→ company_financials → Summary / Waterfall
```

**目指す形**

```
XBRL → statement / notes / breakdown（正本・並列抽出）
         ↓
      company_financials（組立・派生の materialized view）
         ↓
      Summary / Waterfall（＋将来 Allocation/Sankey）
```

- 正本は **直列1本ではなく並列**（いずれも XBRL から自己完結抽出）。クライアントは正本 API
  （`get_statement` / `get_statement_notes` / `get_breakdown`）も直接見られる
- `company_financials` は正本ではなく **ビュー用スナップショット**（Fly read-only・多年次・
  低レイテンシのため、read 時 join は採らない）
- 生値の優先: **statement で足りる → 足りない分を notes / breakdown**
- 派生指標（マージン・NOPAT・ROE/ROIC・ネットキャッシュ等）と Waterfall / 将来 Sankey の組立は
  **`company_financials`（Summary 組立層）経由**に載せる

## 現状の実態（2026-08-12、smoke 11社実測込み）

### financials の中身

`FinancialsYear` は約70フィールド。Summary 配信は水準値、Waterfall は `analysisOnlyKeys` 込み。

### notes

financials 非依存で自己完結抽出済み。smoke では per_share / issued_shares / capex /
policy_holding / dividends が 11/11、borrowings は 9/11（US-GAAP 2社は意図的対象外）など。

### breakdown

分母（売上・employees・rd）を `company_financials` から読む **逆依存**が残る。
R&D 軸の `totalTag` だけ同一 XBRL から独立再解決（タグ透明性の先行例）。

### 二重計算

`eps` / `issued_shares` は notes resolver と `IndividualAnalyzer` が同じ Extractor を別々に呼ぶ。
正本は notes（`per_share_information` / `issued_shares_and_capital`）。

### Summary に無いもの（置換対象外）

| 項目 | 扱い |
|---|---|
| goodwill / 無形明細 | Summary 非搭載。正本は **statement 行**。note は本表に構造が無い会社のフォールバック |
| PPE 区分明細 | Summary は `ppe_total`（合計）のみ。明細は **statement 行**（PPE note は IFRS 等の補完） |

### smoke: statement だけで Summary 水準値を再現できる割合

`TickerDev statement-feasibility`（同一書類。非 US-GAAP）: 売上・利益・BS 合計・PPE 合計・
売掛/棚卸/買掛・現金などは概ね 100%。`employees` / `issued_shares` / `dividend_ss` は 0%、
`capex` ~11%、`eps` ~33%、`rd` ~40%、IBD/CFO/CFI/支払利息/自社株買いは 50–67%。
US-GAAP は Statement HTML（`USGAAPStatementHtml`）と Summary 用 HTML（`USGAAPHtml`）が
別経路で、feasibility 工具は前者未接続（HTML Statement golden 自体は成立）。

## 設計方針（確定）

| 項目 | 方針 |
|---|---|
| 格納 | `company_financials` 維持（materialized view）。案B（read 時 join）は採らない |
| `fin-vN` | 存続。意味を「組立＋未分離抽出」→徐々に「組立＋派生」へ寄せる。床・`blueTickerVersion` 非連動 |
| 新規生値 | financials に足さず、まず statement / notes / breakdown 正本へ |
| 派生・視覚化 | Summary 組立層（`company_financials`）経由（Waterfall / 将来 Sankey 含む） |
| 二重物 | 正本を1つに決め、financials 側はパススルーまたは再計算のみに |

## フィールド別の置き換え見立て（Summary 水準値）

| 帯 | 例 | 置き換え先 |
|---|---|---|
| statement 正本化しやすい | sales / OP / 純利益 / BS 合計類 / ppe_total / AR·在庫·AP / 現金 / dividend_paid_cf 等 | statement 行 |
| notes パススルー本命 | eps / issued_shares / capex（概念差あり）/ dividend_ss | 各 note_type |
| breakdown 正本 | employees / rd | 各軸（分母の逆依存解消が前提） |
| 定義突合が要る | IBD / 支払利息 / buyback / cfo·cfi | statement ± notes。ルール整備後 |
| 派生 | 各種マージン / nopat / roe·roic / net_cash / cfc 等 | 入力付け替え後に financials で再計算 |
| Summary 外 | goodwill 明細・PPE 明細・借入明細・政策保有 | 正本 API のみ（組立に必須ではない） |

## 着手可能なタスク（棚卸）

追跡の正本は GitHub issue（作成は都度確認）。ここでは着手順の索引のみ。

### すぐ着手できる（小〜中、依存が少ない）

| # | タスク | 内容 | 未決・注意 |
|---|---|---|---|
| 1 | **EPS パススルー** | `IndividualAnalyzer` の独自 `PerShareExtractor` 呼び出しをやめ、`resolvePerShareInformation` の `eps` を正本にする | ingest 順: (a) notes 先出し or (b) 同一パスで resolver 直接呼び。公開形は変えない |
| 2 | **issued_shares パススルー** | 同上。`issued_shares_and_capital` の as_of を正本に | #1 と同じ未決 |
| 3 | **値一致回帰** | smoke で financials.eps / issuedShares と notes 正本の一致テストを追加 | #1–2 と同時でよい |
| 4 | **フィールド source 表の固定** | 上表を契約メモ（本ドキュメント or `FinancialsContract` 近傍）として「誰が正本か」を1か所に | 実装前の合意固定 |

### 次（正本→組立の本線）

| # | タスク | 内容 | 未決・注意 |
|---|---|---|---|
| 5 | **本表水準値の statement 参照** | sales / OP / BS 合計 / ppe_total 等を statement 行から組立 | US-GAAP は HTML Statement を組立に配線（`USGAAPHtml` との一本化） |
| 6 | **capex を notes 正本に** | CF 取得額と設備投資総額の概念差を契約で固定し、Summary `capex` を notes から | smoke で notes 11/11 済み |
| 7 | **dividend_ss** | SS 合計列だけでは不足 → notes `dividends` または SS 行規則のどちらを正本にするか決定して実装 | 正本選択が先 |
| 8 | **IBD / 利息 / buyback / CFO·CFI** | statement マッチ率 50–67% の定義を突合し、ルール＋golden | 機械マッチだけでは不足 |

### 逆依存・基盤

| # | タスク | 内容 | 未決・注意 |
|---|---|---|---|
| 9 | **breakdown 分母の正本化** | sales / employees / rd 分母を financials 経由から外す | employees の正本（breakdown 自身 vs 別 note）・銀行分母は既存 bank 経路と整合 |
| 10 | **ingest 順序または共有呼び出し** | financials が正本に依存できる形に | #1 の未決の本決め。DB 間 read 依存は避ける方針が有力 |
| 11 | **再組立トリガ** | statement/notes/breakdown の cache_version 更新時に financials を再計算 | high_water との役割分担 |
| 12 | **notes 本番 ingest** | 正本を組立に使う前提で Neon `company_statement_notes` を埋める | 現状 0 行。組立が DB 参照なら必須、関数共有なら後回し可 |

### 後回し（正本レイヤの拡張・視覚化）

| # | タスク | 内容 |
|---|---|---|
| 13 | goodwill / PPE **明細**の statement 正本化と note フォールバック整理 | Summary 置換ではない |
| 14 | Allocation（Sankey） | breakdown + financials 組立層の上に載せる（`docs/allocation-concept.md`） |
| 15 | `fin-vN` 公開露出・Summary REST 削除など | 非ゴール寄り。契約安定後 |

## 関連ドキュメント

- `docs/feature-tiers.md` — Summary / Waterfall / Statement / Note / Breakdown / Allocation
- `docs/statement-normalization-concept.md` — statements / notes
- `docs/breakdown-normalization-concept.md` — breakdown（分母の financials 依存は今後解消）
- `docs/allocation-concept.md` — Sankey 構想
- `.agents/rules/project/versioning.md` — cache_version
- `docs/blt-server-roadmap.md` — 現在地索引
