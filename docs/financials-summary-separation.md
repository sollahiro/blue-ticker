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

## 現状の逆依存・ギャップ

- breakdown 分母（売上）が financials 経由。employees / rd の Summary 値もまだ Extractor 直読み。
- US-GAAP は Statement HTML と旧 Summary HTML（`USGAAPHtml`）が別経路。後者は撤去対象。
- goodwill / PPE **明細**は Summary 置換対象外（正本 API）。

## 残タスク（未完のみ）

| # | 内容 |
|---|---|
| 5b-2 | 未移行の **statement 正本**フィールドを Statement 組立へ。`USGAAPHtml` 撤去 |
| 5c | gross_profit / sga の statement 参照（TextBlock / 銀行粗利益の整理） |
| 7 | dividend_ss の正本選択（notes `dividends` vs SS 行規則）→実装 |
| 8 | IBD: statement 項目タグ＋notes から取れる項目タグで計算（notes 合計では代用しない）。利息 / buyback / CFO·CFI の statement 突合 |
| 9 | employees / rd は statement に無ければ breakdown 合計。売上分母の financials 逆依存解消 |
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
| statement パススルー | `Analysis/StatementFinancialsResolver.swift` |
| notes | `Analysis/StatementNotesResolver.swift` |
| breakdown 分母 | `BltServerCore/BreakdownIngest.swift` |

## 関連

`feature-tiers.md` · `statement.md` · `breakdown.md` · `versioning.md` · `blt-server-roadmap.md`
