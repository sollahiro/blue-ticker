# Statement / Shares（ドメイン契約）

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
| Shares | `GET /v1/companies/{code}/shares` | `get_shares` |

対象母集団は上場全体（Statement / Shares とも。日経225は処理順の優先のみ）。1書類=1行（ingest が候補 docID を反復）。通期のみ。

## 契約（骨組み）

`StatementContract.swift`: `statementCacheVersion` / min servable、`StatementLineItem`（tag, label, value, unit, order, section?, is_total?, components?）。SS は合計列のみ（`changes_in_equity`）。

行の `label` は presentation の `preferredLabel` が指すロールの文言。`preferredLabel` が無い arc は提出ラベル（標準ロール優先で1つに収束）を使う。ただし収束したラベルが別の表の arc が `preferredLabel` で指すロール（セグメント表用の positiveLabel / alt 等）の文言なら、本表には標準ロールの文言（提出側、無ければ標準タクソノミ）を出す（8766 S100YLS8 / 8725 S100YNCJ の `ProfitLossAttributableToOwnersOfParentIFRS` は「親会社の所有者」。どの arc も指さない alt だけの BS 科目 2413 S100YJ25「短期借入金」は従来どおり）。

## shares

EPS・希薄化後 EPS・BPS・発行済株式総数を、有報の記載そのままで返す（`SharesResponse` = {code, doc_id, items}。`StatementNotesContract.swift`）。items の `key` は `eps` / `diluted_eps` / `bps` / `issued_shares`、`label` は有報の表示名、`unit` は `yen_per_share` / `shares`。開示の無い key は行ごと省く。

- 値の源泉は財務諸表注記取り込み（`company_statement_notes`）の2注記。`per_share_information`（EPS・希薄化後 EPS・BPS）と `issued_shares_and_capital` の期末発行済株式数（`as_of_period_end.issued_shares`、【株式の総数等】→主要な経営指標等の推移のタグ）。書類は 1株当たり情報の行に揃え、別書類の発行済株式は混ぜない。
- 資本金・資本準備金と「発行済株式総数、資本金等の推移」の表は返さず、取り込みもしない（提出会社単体の値で、連結の分析にほとんど使わないため）。`issued_shares_and_capital` の行は期末の発行済株式総数だけ。`cache_version` は据え置き（期末値の意味は変わらない。旧行が持つ資本金・推移のキーは読まない）。旧表パーサの円単位警告（`issued_shares_unit_unresolved`）だけで要確認の旧行も、発行済株式数は shares が返す。
- IFRS の継続事業・非継続事業別の EPS は statement の損益計算書（`ContinuingOperations*EarningsLossPerShareIFRS` 等）にある。shares には足さない。
- financials の `eps` / `bps` / `issued_shares` の正本は同じ2注記（`docs/financials-summary-separation.md`）。

非開示は **404** ＋ボディ `reason`（未取り込みは reason 無し）。shares が返す `reason` は `allSharesNotApplicableReasons`（`not_found` のみ）。

| reason | 意味 |
|---|---|
| `not_found` | 当該書類に開示・タグが無い（正当欠測） |

旧 `GET /v1/companies/{code}/statement/notes`（note_type 指定）は廃止し、常に 404（後継は shares）。

### 注記取り込み（内部）

`company_statement_notes` と ingest ステージ `statement-notes` は shares の源泉として残す。決定論の note_type（`allStatementNoteTypes` = `per_share_information` / `issued_shares_and_capital`）。`allStatementNoteNotApplicableReasons` は内部の reason 一覧（`available_via_*` は廃止した note_type 用）。

廃止した note_type（公開面から外した）:

- `borrowings_schedule` / `lease_liabilities`: パーサは残し、有利子負債は breakdown 軸 `interest_bearing_debt`。
- `property_plant_equipment_schedule` / `goodwill_and_intangibles`: breakdown 軸 `property_plant_equipment` / `goodwill_and_intangibles`（資産の種類別。`docs/breakdown.md`）。

未公開: `sga_expense_breakdown`（販管費の主要な費目内訳。発生支出の `research_and_development` 軸とは別。US-GAAP 非対応）。ingest の現在地は Linear Team `blue-ticker`。

## 非ゴール（当面）

- 企業拡張タグの識別フラグ（需要が出てから）
- 半期報告書（通期のみ）
- PL 利益段階ラベリング（科目統一に当たるため）

## 関連

`breakdown.md` · `financials-summary-separation.md` · `architecture.md` · `.agents/rules/xbrl.md` · `.agents/rules/versioning.md`
