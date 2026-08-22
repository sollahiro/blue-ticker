# Statement / Notes（ドメイン仕様）

有報 XBRL の BS/PL/CF/SS を絞り込みなしで構造化する。**現行の実装方針・再発防止の正本**（構想メモではない）。Summary は主要指標、Breakdown は比較用割合。正本→組立は `docs/financials-summary-separation.md`。

## 目的

| 機能 | 価値 |
|---|---|
| Summary / Waterfall | 固定タグの主要指標 |
| Breakdown | 事業・地域の比較用割合 |
| **Statement** | 開示全項目を忠実に構造化（科目の企業間統一は非ゴール） |

抽出は決定論のみ（presentation / calculation linkbase）。Breakdown と違い自由形式表の意味理解が不要なため LLM は使わない。

## 公開面

別エンドポイント・別テーブル（バージョニング独立。提供面は `feature-tiers.md`）。

| 機能 | REST | MCP |
|---|---|---|
| Statement | `GET /v1/companies/{code}/statement` | `get_statement` |
| Notes | `GET /v1/companies/{code}/statement/notes` | `get_statement_notes` |

対象母集団は日経225スタート。1書類=1行（ingest が候補 docID を反復）。通期のみ。

## 契約（骨組み）

`StatementContract.swift`: `statementCacheVersion` / min servable、`StatementLineItem`（tag, label, value, unit, order, section?, is_total?, components?）。SS は合計列のみ（`changes_in_equity`）。

## 再発防止（学びの要約）

1. **role 分類**: `Notes*` 接頭辞を先に除外（注記ロールに `BalanceSheet` 等が含まれる）。
2. **連結/非連結**: contextRef で判定。非連結は `isPureNonConsolidatedContext`（セグメント軸付きを拾わない）。
3. **表示順 `order`**: 同一 presentation role 内でのみ比較。代表 role は**出現頻度ではなく採用タグ集合のカバレッジ**。取れないタグはアルファベット順フォールバック。
4. **SS**: 別名 loc をマージし期首→変動→期末の order。連結で個別 SS 由来の stray `ProfitLoss` を除外（個別のみ企業は正当行として残す）。
5. **`section`（BS/CF）**: presentation 祖先キーワード。BS 判定順は 純資産→負債→資産（`NetAssets` が `Asset` を部分一致するため）。複数区分に同時一致する祖先は曖昧として上へ。タグ自身名へのフォールバックは単一区分に曖昧さなく一致する場合のみ。
6. **同一タグの二重 loc**: 親候補を集合で持ち BFS。
7. **ラベル**: 提出パッケージ＋ `assets/taxonomy` 補完。`preferredLabel` 対応。期首/期末ラベル差し替えは **CF（と SS）限定**（BS 合計行を巻き込まない）。ロール選択は標準 XBRL ロール優先で決定的に。
8. **CF Instant**: 期首/期末現金は Instant。CF に限り前期 Instant も受理。
9. **`is_total`/`components`**: calculation linkbase（`summation-item`）。presentation の親子では二重計上を防げない。
10. **US-GAAP**: fact 経路不可 → `USGAAPStatementHtml`（当期優先・キヤノン型 components）。見出しゆれ: `（資産）`/`資本：`（証券）、営業利益行なし PL、CF 分割表、SS の `期末現在`/`期首残高`/`YYYY年M月DD日残高`。富士フイルム型の空番号親（`２ 受取債権`）は末子の当期右セルが内訳合計と一致するとき親行として復元。Summary 用 `USGAAPHtml` と混同しない。取れないときだけ `us_gaap_unsupported`。

## notes

決定論の note_type 群（詳細はコードと smoke/golden）。`research_and_development` は breakdown 軸へ集約。ingest の現在地は Linear（親 [BLT-5](https://linear.app/sollahiro/issue/BLT-5/jp-statement-notes)）。

REST/MCP で注記が対象外・非開示のときは **404** ＋ボディ `reason`（未取り込みは reason 無し）。既知 `reason` は `allStatementNoteNotApplicableReasons`（`StatementNotesContract.swift`）が正本:

| reason | 意味 |
|---|---|
| `not_found` | 当該 note_type の開示・タグが無い（正当欠測） |
| `available_via_statement` | 本 note_type 対象外だが同等値は `get-statement` から取得可 |
| `available_via_notes` | 本 note_type 対象外だが同等値は他 note_type（例: `borrowings_schedule`）から取得可 |
| `us_gaap_unsupported` | US-GAAP 連結で本 note_type の構造化タグ判定ができない |

## 非ゴール（当面）

- 企業拡張タグの識別フラグ（需要が出てから）
- 半期報告書（通期のみ）
- PL 利益段階ラベリング（科目統一に当たるため）

母集団拡大は Linear [BLT-28](https://linear.app/sollahiro/issue/BLT-28/statement-母集団拡大銀行保険)。`assets/taxonomy` の本番配置は [BLT-37](https://linear.app/sollahiro/issue/BLT-37/運用-assetstaxonomy-本番配置)。

## 関連

`feature-tiers.md` · `breakdown.md` · `financials-summary-separation.md` · `blt-server-roadmap.md` · `.agents/rules/project/xbrl-analysis.md` · `versioning.md`
