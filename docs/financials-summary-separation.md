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

**組立完成時（`fin-v6`。roadmap）**:

```
XBRL → statement / notes / breakdown（正本・並列）
         ↓
      company_financials（組立スナップショット）
         ↓
      Summary / Waterfall（＋将来 Sankey）
```

- 正本 API も直接公開。`company_financials` は materialized view（read 時 join は採らない）。
- 生値: statement で足りる → 足りない分を notes / breakdown。派生は組立層。

## 設計方針（確定）

| 項目 | 方針 |
|---|---|
| 格納 | `company_financials` 維持 |
| `fin-vN` | 存続。**組立ができた段階で `fin-v6` に切替。それまでバンプしない**（roadmap） |
| 新規生値 | まず正本へ。financials に足さない |
| 二重物 | 正本を1つに決め、financials はパススルー／再計算 |
| ingest 依存 | 順序変更は採らない。**同一 XBRL パスで resolver 直接呼び（#10b）** |

正本の原則: XBRL タグ優先。表パース行を Summary 水準値の正にしない（タグを読む）。

## 現状の逆依存・ギャップ

- breakdown 分母（売上・employees・rd）が financials 経由。
- statement 単独では `employees` / `issued_shares` / `dividend_ss` 等が不足しやすい（feasibility）。
- US-GAAP は Statement HTML と Summary HTML が別経路。
- goodwill / PPE **明細**は Summary 置換対象外（正本 API）。

## 残タスク（未完のみ）

| # | 内容 |
|---|---|
| 5b-2 | 未移行フィールドも Statement 組立へ。`USGAAPHtml` 撤去 |
| 5c | gross_profit / sga の statement 参照（TextBlock / 銀行粗利益の整理） |
| 7 | dividend_ss の正本選択（notes `dividends` vs SS 行規則）→実装 |
| 8 | IBD / 利息 / buyback / CFO·CFI の定義突合＋golden |
| 9 | breakdown 分母の正本化 |
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
