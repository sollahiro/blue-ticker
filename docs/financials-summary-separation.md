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
- **組立**: そのフィールドを計算できることが前提。statement で取れたらそれ。取れなければ notes、それも無ければ breakdown。**employees / rd は breakdown 分母が正本**（statement PL の研究開発行は使わない）。1 値を複数源の**合計同士**から足し合わせない。IBD は下表（項目タグの合算。notes 合計での代用ではない）。`available_via_*` は notes の 404 理由であり組立の分岐ではない。
- 派生は組立層。financials 層で XBRL を再解釈しない。

## 設計方針（確定）

| 項目 | 方針 |
|---|---|
| 格納 | `company_financials` 維持 |
| `fin-vN` | 存続。IBD の notes リース欠測埋めは `fin-v6`。途中の IA 切替（値の意味が変わらない配線）ではバンプしない。Extractor の符号・抽出意味が変わったら上げる（現行 `fin-v7`: US-GAAP 自己株式取得の絶対値）。組立完成（Extractor 残件の切替後）が次世代 |
| 新規生値 | まず正本へ。financials に足さない |
| 組立 | statement → notes → breakdown。取れた源を1つ採用。**employees / rd は breakdown のみ** |
| IBD | 有利子負債の**項目タグを合算**する。statement にある項目（内訳でも「社債及び借入金」のような集約でも、BS の粒度）を使う。その上に notes の内訳を足さない（二重計上）。statement に無い項目は notes のタグを足してよい（典型はリース帳簿。`borrowings_schedule` 区分 / `lease_liabilities`）。notes の合計行で IBD 全体を置き換えない。金融負債そのものは使わない（味の素: その他の金融負債 ≠ リース帳簿） |
| employees / rd | breakdown 軸の分母。financials はパススルー。PL 行は使わない |
| ingest 依存 | 順序変更は採らない。**同一 XBRL パスで resolver 直接呼び（#10b）** |

正本の原則: 水準値は正本 resolver の結果。statement は XBRL タグ（US-GAAP 本表は `USGAAPStatementHtml`）。notes の表パースは notes 側。financials は選んで渡すだけ。

## smoke 組立到達（固定11社）

`testRemainingFieldsComposeVsSmoke`。cell は statement / composed（statement → notes → breakdown） / 現行 Extractor。IBD は PR #247。#5c フィールドは IndividualAnalyzer 切替済。

| フィールド | statement | composed | 現行 | メモ |
|---|---|---|---|---|
| gross_profit | 11/11 | 11/11 | 11/11 | IA 切替済（#5c） |
| sga | 9/9 | 9/9 | 9/9 | 銀行2社は期待値なし。IA 切替済（#5c） |
| pretax_income | 11/11 | 11/11 | 11/11 | 公開フィールドではないが税計算入力。IA 切替済（#5c） |
| rd | — | 7/7 | 7/7 | **breakdown `research_and_development` 分母が正本**。PL 行は使わない |
| employees | — | 11/11 | 11/11 | **breakdown `employees` 分母が正本**。本表に人数行なし |
| cfo / cfi | 11/11 | 11/11 | 11/11 | CF 本表合計。IA 切替済（#5c）。IFRS 3社は `NetCashProvidedByUsedIn*ActivitiesIFRS`（Summary は正本にしない） |
| income_tax | 11/11 | 11/11 | 11/11 | IA 切替済（#5c）。US-GAAP は合計行（キヤノン）または当期税＋繰延（富士フイルム）。`法人税等` 部分一致は調整額に当たるため使わない |
| dividend_ss | 11/11 | 11/11 | 11/11 | IA 切替済（#5c）。statement SS。US-GAAP も SS あり（合計列）。減少額は負 → financials はキャッシュアウト正に反転 |
| cf_treasury_stock | 10/10 | 10/10 | 10/10 | US-GAAP は CF HTML の取得行。△ はキャッシュアウト正。IA はまだ Extractor |
| interest_expense | 6/9 | 9/9 | 9/9 | statement は PL 行（US-GAAP は △ を絶対値）。IFRS 3社は notes の支払利息タグ。PL の FinanceCostsIFRS は使わない。IA はまだ Extractor |
| buyback | 10/10 | 10/10 | 10/10 | `testSmokeAll` の床。US-GAAP は SS/CF 取得行の絶対値。IA はまだ Extractor |

## 現状の逆依存・ギャップ

- breakdown 売上分母が financials 経由。employees / rd の ingest 分母もまだ financials から渡している（正本は breakdown。financials は分母パススルーへ寄せる）。
- US-GAAP は Statement HTML（`USGAAPStatementHtml`）が本表正本。旧 Summary HTML（`USGAAPHtml`）は IBD / 利息 / buyback / cf_treasury_stock の Extractor 残件のみ。
- goodwill / PPE **明細**は Summary 置換対象外（正本 API）。

## 残タスク（未完のみ）

| # | 内容 |
|---|---|
| 5b-2 | 残りの **statement 正本**フィールド（利息 / buyback / cf_treasury_stock / IBD）を IndividualAnalyzer へ切替。`USGAAPHtml` 撤去 |
| 8 | IBD 定義は PR #247。利息は statement 6/9（IFRS 3社は notes タグ）、cf_treasury_stock / buyback は 10/10。IA はまだ Extractor |
| 9 | employees / rd の正本は breakdown 分母。financials はパススルー。ingest はまだ financials → breakdown の逆依存。売上分母も financials 逆依存 |
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
| statement パススルー | `Analysis/StatementFinancialsResolver.swift`（本表＋#8 未配線フィールドの statement 値） |
| remaining vs smoke | `SwiftTests/BlueTickerTests/Spec/Oracle/SmokeTests.swift`（`testRemainingFieldsComposeVsSmoke`） |
| notes | `Analysis/StatementNotesResolver.swift` |
| breakdown 分母 | `Analysis/BreakdownFinancialsResolver.swift`（employees / rd）。売上は `BltServerCore/BreakdownIngest.swift` |

## 関連

`feature-tiers.md` · `statement.md` · `breakdown.md` · `versioning.md` · `blt-server-roadmap.md`
