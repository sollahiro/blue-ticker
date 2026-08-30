# Breakdown（ドメイン契約）

企業間比較（同業の割合）と同一企業の期ごと推移が目的。**同じ形の割合（軸・分母・外部売上）で並べること**が本体。行ラベルの会社間統一はしない。抽出の再発防止は `.agents/skills/xbrl-development/SKILL.md`。正本分離は `docs/financials-summary-separation.md`。

## 方針（確定）

- 事業再編・名称変更の過去遡及補正はしない。各期はその期の開示どおり。
- 会社間の行ラベル対応は必須にしない。比較は構造（軸・分母・割合）まで。
- `segments` / `geography` は開示ブロックの取り分け。事業×地域の両方が常にあることは保証しない。
- 原則指標は外部顧客売上。分母は連結の外部売上（調整後）。金融機関は別経路（粗利益等）。

## 抽出の二段

1. TextBlock 内 HTML 表 → `html_table`
2. dimension 付き数値 fact → `xbrl_facts`

| API キー | 意味 |
|---|---|
| `segments` | 報告セグメント（事業とも地域とも限らない） |
| `geography` | 地域別注記 |
| `segment_assets` | 報告セグメントごとの資産（銀行の「固定資産」含む） |
| `depreciation_and_amortization` | 報告セグメントごとの減価償却費及び償却費（J-GAAPは減価償却費） |
| `goodwill_amortization` | 報告セグメントごとののれんの償却額 |
| `impairment_loss` | 報告セグメントごとの減損損失 |
| `equity_method_investments` | 報告セグメントごとの持分法会計処理される投資 |
| `capital_expenditures` | 報告セグメントごとの資本的支出 |
| `capital_expenditures_overview` | notes「設備投資等の概要」のセグメント別Capex（`capital_expenditures`とは別値）。US-GAAP も Overview タグにセグメント dimension 付き fact があり決定論で再構成可能 |
| `noncurrent_asset_additions` | 報告セグメントごとの非流動性資産／固定資産への追加額 |

公開軸（意味。公開判断の現在地は Linear [JP 現在地](https://linear.app/sollahiro/document/jp-現在地-af2abd076034)）:

| axis | 内容 |
|---|---|
| `business` | 事業別売上 |
| `geography` | 地域別売上 |
| `employees` | 従業員内訳 |
| `research_and_development` | 研究開発費内訳（発生支出） |
| `goodwill` | のれん |
| `segment_assets` 他7指標 | 報告セグメント別指標 |

## 契約・永続化

- 比較用スナップショット: `BreakdownSnapshot`（`BreakdownContract.swift` / `BreakdownNormalizer`）。
- 保存: `company_breakdowns`（filing-sections とは別。LLM 行を filing バンプに巻き込まない）。主キー `doc_id#axis`。
- `not_found` は行を作らない。business の E/F/unknown は `not_applicable` プレースホルダ。REST と開発用 MCP は 404＋ボディ `reason`（200 化しない）。
- 対象母集団: business/geography は上場全体（日経225は処理順の優先のみ）。employees / rd / goodwill および報告セグメント別指標軸は日経225。read は Fly 専用（ingest 時に LLM 計算）。処理順は各社の最新有報 → 前年以降。同一年次内は日経225 → ローカル XBRL 展開済み → 欠測/要再試行/版ずれのラウンドロビン（軸ごとにキャッシュ集合を取り直す）。
- 売上分母・employees / rd の Summary 正本は breakdown 分母（ingest も同一 XBRL パスで直接解決）。
- 報告セグメント別指標の分母は常に segment + reconciling（表の小計・EntityTotal は行として保持し、分母切替には使わない）。

## 非目標

過去セグメント遡及組替、会社間ラベル統一、全期の事業×地域完全充足、生 XBRL 一発 LLM 抽出。
