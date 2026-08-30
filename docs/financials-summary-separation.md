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
| `fin-vN` | 存続。IA 切替（値の意味が変わらない配線）ではバンプしない。Extractor の符号・抽出意味が変わったら上げる |
| 新規生値 | まず正本へ。financials に足さない |
| 組立 | statement → notes → breakdown。取れた源を1つ採用。**employees / rd は breakdown のみ** |
| IBD | 有利子負債の**項目タグを合算**する。statement にある項目（内訳でも「社債及び借入金」のような集約でも、BS の粒度）を使う。その上に notes の内訳を足さない（二重計上）。statement に無い項目は notes のタグを足してよい（典型はリース帳簿。`borrowings_schedule` 区分 / `lease_liabilities`）。notes の合計行で IBD 全体を置き換えない。金融負債そのものは使わない |
| employees / rd | breakdown 軸の分母。financials はパススルー。PL 行は使わない |
| ingest 依存 | 順序変更は採らない。同一 XBRL パスで resolver 直接呼び。正本 `cache_version` が変わったら `assembly_fingerprint` 不一致で financials を再組立する（`fin-vN` は上げない） |

正本の原則: 水準値は正本 resolver の結果。statement は XBRL タグ（US-GAAP 本表は `USGAAPStatementHtml`。`USGAAPHtml` は仮想タグヘルパと Extractor 単体テスト用）。notes の表パースは notes 側。financials は選んで渡すだけ。goodwill / PPE 明細は Summary 置換対象外（正本 API）。

## コード索引

| 用途 | パス |
|---|---|
| 正本索引 | `Models/FinancialsContract.swift`（`フィールド正本`） |
| 組立指紋 | `financialsAssemblyFingerprint`（`company_financials.assembly_fingerprint`） |
| 組立 | `Services/IndividualAnalyzer.swift` |
| statement パススルー | `Analysis/StatementFinancialsResolver.swift` |
| IBD 組立 | `IBDExtractor.extractCanonical` |
| notes | `Analysis/StatementNotesResolver.swift` |
| breakdown 分母 | `Analysis/BreakdownFinancialsResolver.swift`（sales / employees / rd） |

## 関連

`statement.md` · `breakdown.md` · `.agents/rules/versioning.md` · `architecture.md`
