# Statement / Notes（ドメイン契約）

有報 XBRL の BS/PL/CF/SS を絞り込みなしで構造化する。Summary は主要指標、Breakdown は比較用割合。正本→組立は `docs/financials-summary-separation.md`。抽出の再発防止は `.agents/skills/xbrl-development/SKILL.md`。

## 目的

| 機能 | 価値 |
|---|---|
| Summary / Waterfall | 固定タグの主要指標 |
| Breakdown | 事業・地域の比較用割合 |
| **Statement** | 開示全項目を忠実に構造化（科目の企業間統一は非ゴール） |

抽出は決定論のみ（presentation / calculation linkbase）。Breakdown と違い自由形式表の意味理解が不要なため LLM は使わない。

## 公開面

別エンドポイント・別テーブル（バージョニング独立）。

| 機能 | REST | 開発用 MCP |
|---|---|---|
| Statement | `GET /v1/companies/{code}/statement` | `get_statement` |
| Notes | `GET /v1/companies/{code}/statement/notes` | `get_statement_notes` |

対象母集団は上場全体（日経225は処理順の優先のみ。Notes は当面225）。1書類=1行（ingest が候補 docID を反復）。通期のみ。

## 契約（骨組み）

`StatementContract.swift`: `statementCacheVersion` / min servable、`StatementLineItem`（tag, label, value, unit, order, section?, is_total?, components?）。SS は合計列のみ（`changes_in_equity`）。

## notes

決定論の公開 note_type 群（詳細はコードと smoke/golden）。`research_and_development` は breakdown 軸へ集約（発生支出）。販管費の**費目**内訳 `sga_expense_breakdown`（BLT-46）は実装済みだが **未公開・未配線**（ingest / REST / 開発用 MCP / job-03 に載せない）。ingest の現在地は Linear（親 [BLT-5](https://linear.app/sollahiro/issue/BLT-5/jp-statement-notes)）。

注記が対象外・非開示のときは **404** ＋ボディ `reason`（未取り込みは reason 無し）。既知 `reason` は `allStatementNoteNotApplicableReasons`（`StatementNotesContract.swift`）が正本:

| reason | 意味 |
|---|---|
| `not_found` | 当該 note_type の開示・タグが無い（正当欠測） |
| `available_via_statement` | 本 note_type 対象外だが同等値は statement から取得可 |
| `available_via_notes` | 本 note_type 対象外だが同等値は他 note_type（例: `borrowings_schedule`）から取得可 |
| `us_gaap_unsupported` | US-GAAP 連結で本 note_type の構造化タグ判定ができない |

公開 note_type:

| note_type | 内容 |
|---|---|
| `per_share_information` | 1 株当たり情報 |
| `issued_shares_and_capital` | 発行済株式・資本金等 |
| `dividends` | 配当 |
| `borrowings_schedule` | 借入金等明細 |
| `property_plant_equipment_schedule` | 有形固定資産明細 |
| `goodwill_and_intangibles` | のれん・無形資産 |
| `lease_liabilities` | リース負債 |
| `policy_holding_securities` | 政策保有株式 |

未公開: `sga_expense_breakdown`（販管費の主要な費目内訳。発生支出の `research_and_development` 軸とは別。US-GAAP 非対応）。

## 非ゴール（当面）

- 企業拡張タグの識別フラグ（需要が出てから）
- 半期報告書（通期のみ）
- PL 利益段階ラベリング（科目統一に当たるため）

## 関連

`breakdown.md` · `financials-summary-separation.md` · `architecture.md` · `.agents/rules/xbrl.md` · `.agents/rules/versioning.md`
