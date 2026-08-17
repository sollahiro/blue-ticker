# financials（Summary）と正本の分離

`company_financials`（公開面は Summary / Waterfall）を、正本（statement / notes / breakdown）からの組立ビューへ寄せる**進行中の設計**。ドメイン個別の仕様は `statement.md` / `breakdown.md`。

## 用語

| 名 | 意味 |
|---|---|
| financials | 実装・Neon（`company_financials` / `.../financials`） |
| Summary | 水準値投影（`get_financial_summary`） |
| Waterfall | 同行走査の分析投影（`get_waterfall`） |

1行 JSONB に同居し、read 時投影で分かれる。Summary 専用テーブルはない。

## データフロー

**いま**: `XBRL → IndividualAnalyzer → company_financials → Summary/Waterfall`

**組立完成時（次世代。roadmap）**:

```
XBRL → statement / notes / breakdown（正本・並列）
         ↓
      company_financials（組立スナップショット）
         ↓
      Summary / Waterfall（＋将来 Sankey）
```

- 正本 API も直接公開。`company_financials` は materialized view（read 時 join は採らない）。
- 生値の正本は **statement / notes / breakdown のみ**（Filing は本文ではない）。
- **組立**: そのフィールドを計算できることが前提。statement で取れたらそれ。取れなければ notes、それも無ければ breakdown。1 値を複数源の**合計同士**から足し合わせない。IBD は下表（項目タグの合算。notes 合計での代用ではない）。`available_via_*` は notes の 404 理由であり組立の分岐ではない。
- 派生は組立層。financials 層で XBRL を再解釈しない。

## 設計方針（確定）

| 項目 | 方針 |
|---|---|
| 格納 | `company_financials` 維持 |
| `fin-vN` | 存続。IBD の notes リース欠測埋めは `fin-v6`。組立完成は次世代 |
| 新規生値 | まず正本へ。financials に足さない |
| 組立 | statement → notes → breakdown。取れた源を1つ採用 |
| IBD | 有利子負債の**項目タグを合算**する。statement にある項目（内訳でも「社債及び借入金」のような集約でも、BS の粒度）を使う。その上に notes の内訳を足さない（二重計上）。statement に無い項目は notes のタグを足してよい（典型はリース帳簿。`borrowings_schedule` 区分 / `lease_liabilities`）。notes の合計行で IBD 全体を置き換えない。金融負債そのものは使わない（味の素: その他の金融負債 ≠ リース帳簿） |
| ingest 依存 | 順序変更は採らない。**同一 XBRL パスで resolver 直接呼び（#10b）** |

正本の原則: 水準値は正本 resolver の結果。statement は XBRL タグ（US-GAAP 本表は `USGAAPStatementHtml`）。notes の表パースは notes 側。financials は選んで渡すだけ。

## smoke 組立到達（固定11社）

`testRemainingFieldsComposeVsSmoke`。cell は statement / composed（statement → notes → breakdown） / 現行 Extractor。IBD は PR #247。IndividualAnalyzer は未切替。

| フィールド | statement | composed | 現行 | メモ |
|---|---|---|---|---|
| gross_profit | 11/11 | 11/11 | 11/11 | resolver 載済。IA 未切替 |
| sga | 9/9 | 9/9 | 9/9 | 銀行2社は期待値なし。resolver 載済 |
| pretax_income | 11/11 | 11/11 | 11/11 | 公開フィールドではないが税計算入力。resolver 載済 |
| rd | 4/7 | 7/7 | 7/7 | statement に無ければ RD タグ（breakdown 分母と同じ） |
| employees | 0/11 | 11/11 | 11/11 | 本表に人数行なし。従業員タグ（breakdown 分母と同じ） |
| cfo / cfi | 8/11 | 8/11 | 11/11 | IFRS 3社（味の素・クボタ・スズキ）は CF 合計が `SummaryOfBusinessResults` のみ。Summary は正本にしない |
| income_tax | 10/11 | 10/11 | 11/11 | 富士フイルム US-GAAP は statement ラベルと現行 HTML 節抽出が不一致 |
| dividend_ss | 9/11 | 9/11 | 11/11 | US-GAAP 2社。notes `dividends` 合計では埋まらない |
| cf_treasury_stock | 8/10 | 8/10 | 10/10 | US-GAAP 2社は現行 `USGAAPHtml` 専用抽出 |
| interest_expense | 4/9 | 4/9 | 9/9 | IFRS TextBlock / US-GAAP HTML。notes 文章埋めは statement と不一致 |
| buyback | 8/10 | 8/10 | 8/10 | `testSmokeAll` の床に無い。US-GAAP 2社は現行 Extractor も不一致 |

## 現状の逆依存・ギャップ

- breakdown 分母（売上）が financials 経由。employees / rd の Summary 値もまだ Extractor 直読み（組立ではタグで smoke 再現可）。
- US-GAAP は Statement HTML と旧 Summary HTML（`USGAAPHtml`）が別経路。後者は撤去対象。
- goodwill / PPE **明細**は Summary 置換対象外（正本 API）。

## 残タスク（未完のみ）

| # | 内容 |
|---|---|
| 5b-2 | 未移行の **statement 正本**フィールドを IndividualAnalyzer へ切替。`USGAAPHtml` 撤去 |
| 5c | GP / SGA / pretax は statement で smoke 到達。resolver 載済・IA 未切替 |
| 7 | dividend_ss は statement SS 9/11。notes 合計では US-GAAP 欠測を埋めない |
| 8 | IBD 定義は PR #247。CFO·CFI 8/11（IFRS 3社は Summary のみ）。利息 4/9、buyback 8/10 |
| 9 | employees / rd は statement に無ければ同一 XBRL タグ（breakdown 分母）。売上分母の financials 逆依存解消 |
| 11 | 正本 cache_version 更新時の financials 再組立トリガ |
| 12 | notes 本番 ingest（DB 参照組立を採る場合。#10b なら後回し可） |
| 13+ | 明細整理・Sankey・契約露出変更は後回し |

完了済み（EPS/issued_shares/本表の一部/capex パススルー等）の経緯は Git。

## 落とし穴

- analysis_cache の **symlink → 0 facts**。実コピー（`cp -a`）を使う（`.agents/rules/project/caching.md`）。
- `USGAAPStatementHtml` と `USGAAPHtml` を混同しない。
- goodwill note は Summary 置換候補ではない。

## コード索引

| 用途 | パス |
|---|---|
| 正本索引 | `Models/FinancialsContract.swift`（`フィールド正本`） |
| 組立 | `Services/IndividualAnalyzer.swift` |
| statement パススルー | `Analysis/StatementFinancialsResolver.swift`（本表＋未配線フィールドの statement 値） |
| remaining vs smoke | `SwiftTests/BlueTickerTests/Spec/Oracle/SmokeTests.swift`（`testRemainingFieldsComposeVsSmoke`） |
| notes | `Analysis/StatementNotesResolver.swift` |
| breakdown 分母 | `BltServerCore/BreakdownIngest.swift` |

## 関連

`feature-tiers.md` · `statement.md` · `breakdown.md` · `versioning.md` · `blt-server-roadmap.md`
