# financials（Summary）と正本の分離

`company_financials`（公開面は Summary / Waterfall）を、正本（statement / notes / breakdown）からの組立ビューへ寄せる**現行の設計**。ドメイン個別の仕様は `statement.md` / `breakdown.md`。`fin-vN` のバンプ規則は `.agents/rules/versioning.md`。

## 用語

| 名 | 意味 |
|---|---|
| financials | 実装・Neon（`company_financials` / `.../financials`） |
| Summary | 水準値投影（`get_financial_summary` / `GET .../financials`） |
| Waterfall | 同行走査の分析投影（`get_waterfall` / `GET .../waterfall`） |

1行 JSONB に同居し、read 時投影で分かれる。Summary 専用テーブルはない。

## データフロー

同一 XBRL パスで resolver 直呼び:

```
XBRL → statement / notes / breakdown（正本）
         ↓
      IndividualAnalyzer（組立スナップショット）
         ↓
      company_financials → Summary / Waterfall
```

- 正本 API も直接公開。`company_financials` は materialized view（read 時 join は採らない）。
- 生値の正本は **statement / notes / breakdown のみ**（Filing は本文ではない）。
- **組立**: そのフィールドを計算できることが前提。statement で取れたらそれ。取れなければ notes、それも無ければ breakdown。**employees / rd は breakdown 分母が正本**（statement PL の研究開発行は使わない）。1 値を複数源の**合計同士**から足し合わせない。IBD は下表（項目タグの合算。notes 合計での代用ではない）。`available_via_*` は notes の 404 理由であり組立の分岐ではない。
- 派生は組立層。financials 層で XBRL を再解釈しない。

## 設計方針（確定）

| 項目 | 方針 |
|---|---|
| 格納 | `company_financials` 維持 |
| `fin-vN` | 存続。破壊的変更だけバンプ（`.agents/rules/versioning.md`）。IA 切替や既存の正しい値を保つ細粒度修正では上げない |
| 新規生値 | まず正本へ。financials に足さない |
| 組立 | statement → notes → breakdown。取れた源を1つ採用。**employees / rd は breakdown のみ** |
| IBD | breakdown `interest_bearing_debt` 軸の合計行（= `in_total=true` の行の和。全行の和ではない。decider 無し）。銀行は bank components 行の合計。軸が `needs_review`（公開保留）・`not_found`・解決不能のときは既存の `IBDExtractor.extractCanonical` 値をそのまま使い、内部の method `legacy_ibd_extractor_fallback` と warnings に理由（未確認の Jev 分類行など）を残す（公開フィールドは増やさない）。無借金の 0 は旧 Extractor の `zero_debt` のまま |
| 銀行業の比率 | 銀行（IBD の銀行判定 `isBank` = statement Instant に `DepositsLiabilitiesBNK`、または EDINET コードリストの提出者業種が銀行業（ゆうちょ 7182）。bank components と同じ判定。保険・証券は対象外）は `net_cash` / `net_de` / `roic` / `nopat_margin` / `invested_capital_turnover` を null。預金を IBD に含めないため有利子負債ベースの比率は意味を持たない（2026-10-12 決定）。`interest_bearing_debt`（預金を除く）は残す。Waterfall の `net_cash_change` / `debt_change_impact` も null（`cash_change_impact` は残す）。キーは増やさない |
| employees / rd | breakdown 軸の分母。financials はパススルー。PL 行は使わない |
| 資金配分 | Waterfall 専用（Summary には出さない）。statement の CF 本表行から組む（`CashAllocationResolver`）。`cff`（財務CF合計）、`cf_debt_change`（借入金・社債・CP・リース負債の増減。BS の `interest_bearing_debt` 軸と同じくリース込み）、`cf_dividends_parent`（親会社株主への配当）、`cf_buyback`（自己株式の取得による支出。取得と処分を純額で 1 行にした書類はその行。処分による収入・子会社が持つ自己株式の取得は含めない。支払は負）、`cf_other_financing`（財務CF − 有利子負債の増減 − 配当 − 自己株式の取得。自己株式の処分による収入・非支配持分への配当などを含む）、`cf_fx_effect`（換算差額。行が無い書類は 0）、`cf_cash_change`（CF 本表の期末残高 − 期首残高）、`cf_other_cash_change`（現金増減 − 営業CF − 投資CF − 財務CF − 換算差額。連結範囲の変更・売却目的資産への振替など3区分の外の行）。符号は CF のまま（収入が正、支出が負）で、`cfc + cff + cf_fx_effect + cf_other_cash_change = cf_cash_change`。財務CFの行は 標準タグの一覧 → 会社拡張タグのラベル規則 → 決まらない行だけ Jev（区分だけ選ぶ。0.9・3 回一致。金額は返させない）の順で区分し、区分した行の和が財務CF合計に 行数 × 1百万円（百万円単位の行ごとの丸め）の範囲で一致したときだけ内訳を出す（未区分・不一致・キー無しは3つとも null）。銀行は内訳を null（`cff` / 換算差額 / 現金増減は残す）。US-GAAP は HTML 本表の区分が揃わないので全て null。Jev の判断は `company_financials.llm_audit.cashAllocationJev` |
| ingest 依存 | 順序変更は採らない。同一 XBRL パスで resolver 直接呼び。正本 `cache_version` が変わったら `assembly_fingerprint` 不一致で financials を再組立する（`fin-vN` は上げない） |

正本の原則: 水準値は正本 resolver の結果。statement は XBRL タグ（US-GAAP 本表は `USGAAPStatementHtml`。`USGAAPHtml` は仮想タグヘルパと Extractor 単体テスト用）。notes の表パースは notes 側。financials は選んで渡すだけ。goodwill / PPE 明細は Summary 置換対象外（正本 API）。

## コード索引

| 用途 | パス |
|---|---|
| 正本索引 | `Models/FinancialsContract.swift`（`フィールド正本`） |
| 組立指紋 | `financialsAssemblyFingerprint`（`company_financials.assembly_fingerprint`） |
| 組立 | `Services/IndividualAnalyzer.swift` |
| statement パススルー | `Analysis/StatementFinancialsResolver.swift` |
| IBD 組立 | `BreakdownFinancialsResolver.financialsCanonicalInterestBearingDebt` |
| notes | `Analysis/StatementNotesResolver.swift` |
| breakdown 分母 | `Analysis/BreakdownFinancialsResolver.swift`（sales / employees / rd） |

## 関連

`statement.md` · `breakdown.md` · `.agents/rules/versioning.md` · `architecture.md`
