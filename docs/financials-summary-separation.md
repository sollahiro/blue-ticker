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

**いま**（同一 XBRL パスで resolver 直呼び、#10b）:

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
| `fin-vN` | 存続。IBD の notes リース欠測埋めは `fin-v6`。IA 切替（値の意味が変わらない配線）ではバンプしない。Extractor の符号・抽出意味が変わったら上げる（現行 `fin-v9`: Summary に BPS。`fin-v8`: IFRS `TotalNetRevenuesIFRS` を売上候補に追加。`fin-v7`: US-GAAP 自己株式取得の絶対値） |
| 新規生値 | まず正本へ。financials に足さない |
| 組立 | statement → notes → breakdown。取れた源を1つ採用。**employees / rd は breakdown のみ** |
| IBD | 有利子負債の**項目タグを合算**する。statement にある項目（内訳でも「社債及び借入金」のような集約でも、BS の粒度）を使う。その上に notes の内訳を足さない（二重計上）。statement に無い項目は notes のタグを足してよい（典型はリース帳簿。`borrowings_schedule` 区分 / `lease_liabilities`）。notes の合計行で IBD 全体を置き換えない。金融負債そのものは使わない（味の素: その他の金融負債 ≠ リース帳簿） |
| employees / rd | breakdown 軸の分母。financials はパススルー。PL 行は使わない |
| ingest 依存 | 順序変更は採らない。**同一 XBRL パスで resolver 直接呼び（#10b）**。正本 `cache_version` が変わったら `assembly_fingerprint` 不一致で financials を再組立する（#11。`fin-vN` は上げない） |

正本の原則: 水準値は正本 resolver の結果。statement は XBRL タグ（US-GAAP 本表は `USGAAPStatementHtml`）。notes の表パースは notes 側。financials は選んで渡すだけ。

## smoke 組立到達（固定11社）

`testRemainingFieldsComposeVsSmoke`。cell は statement / composed（statement → notes → breakdown） / IA 組立。IBD は `IBDExtractor.extractCanonical`。水準値は IndividualAnalyzer 切替済。

| フィールド | statement | composed | 現行 | メモ |
|---|---|---|---|---|
| gross_profit | 11/11 | 11/11 | 11/11 | IA 切替済（#5c） |
| sga | 9/9 | 9/9 | 9/9 | 銀行2社は期待値なし。IA 切替済（#5c） |
| pretax_income | 11/11 | 11/11 | 11/11 | 公開フィールドではないが税計算入力。IA 切替済（#5c） |
| rd | — | 7/7 | 7/7 | **breakdown `research_and_development` 分母が正本**。IA 切替済 |
| employees | — | 11/11 | 11/11 | **breakdown `employees` 分母が正本**。IA 切替済 |
| cfo / cfi | 11/11 | 11/11 | 11/11 | CF 本表合計。IA 切替済（#5c）。IFRS 3社は `NetCashProvidedByUsedIn*ActivitiesIFRS`（Summary は正本にしない） |
| income_tax | 11/11 | 11/11 | 11/11 | IA 切替済（#5c）。US-GAAP は合計行（キヤノン）または当期税＋繰延（富士フイルム）。`法人税等` 部分一致は調整額に当たるため使わない |
| dividend_ss | 11/11 | 11/11 | 11/11 | IA 切替済（#5c）。statement SS。US-GAAP も SS あり（合計列）。減少額は負 → financials はキャッシュアウト正に反転 |
| cf_treasury_stock | 10/10 | 10/10 | 10/10 | US-GAAP は CF HTML の取得行。△ はキャッシュアウト正。IA 切替済（#8） |
| interest_expense | 6/9 | 9/9 | 9/9 | statement は PL 行（US-GAAP は △ を絶対値）。IFRS 3社は notes の支払利息タグ。PL の FinanceCostsIFRS は使わない。IA 切替済（#8） |
| buyback | 10/10 | 10/10 | 10/10 | `testSmokeAll` の床。US-GAAP は SS/CF 取得行の絶対値。IA 切替済（#8） |
| eps | — | 11/11 | 11/11 | notes `per_share_information` tag=eps。IA 切替済 |
| bps | — | 11/11 | 11/11 | notes `per_share_information` tag=bps。IA 切替済 |

## 現状の逆依存・ギャップ

- US-GAAP 本表は `USGAAPStatementHtml`。`USGAAPHtml` は仮想タグヘルパと Extractor 単体テスト用。
- goodwill / PPE **明細**は Summary 置換対象外（正本 API）。

## 残タスク

notes 本番 ingest・Sankey・契約露出は Linear（[BLT-5](https://linear.app/sollahiro/issue/BLT-5/jp-statement-notes) / [BLT-18](https://linear.app/sollahiro/issue/BLT-18/sankey要求具体化後)）。完了済み（EPS/issued_shares/本表パススルー/利息・buyback・IBD の IA 切替等）の経緯は Git。

## 落とし穴

- analysis_cache の **symlink → 0 facts**。実コピー（`cp -a`）を使う（`.agents/rules/project/caching.md`）。
- `USGAAPStatementHtml` と `USGAAPHtml` を混同しない。
- goodwill note は Summary 置換候補ではない。

## コード索引

| 用途 | パス |
|---|---|
| 正本索引 | `Models/FinancialsContract.swift`（`フィールド正本`） |
| 組立指紋 | `financialsAssemblyFingerprint`（`company_financials.assembly_fingerprint`。#11） |
| 組立 | `Services/IndividualAnalyzer.swift` |
| statement パススルー | `Analysis/StatementFinancialsResolver.swift` |
| IBD 組立 | `IBDExtractor.extractCanonical` |
| remaining vs smoke | `SwiftTests/BlueTickerTests/Spec/Oracle/SmokeTests.swift`（`testRemainingFieldsComposeVsSmoke`） |
| notes | `Analysis/StatementNotesResolver.swift` |
| breakdown 分母 | `Analysis/BreakdownFinancialsResolver.swift`（sales / employees / rd）。ingest は resolve 側が同一 XBRL パスで直接解決（#9） |

## 関連

`feature-tiers.md` · `statement.md` · `breakdown.md` · `versioning.md` · `blt-server-roadmap.md`
