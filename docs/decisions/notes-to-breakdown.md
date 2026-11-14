# statement-notes の縮小と Breakdown への集約

出典: 旧課題管理のチケット（移行日 2026-11-12）。当時の題名: 方針：statement-notes を縮小し Breakdown に集約（interest_bearing_debt 軸の新設）。
この文書は決定・契約の正本としてリポジトリで維持する。件数や進捗の最新値はここに書かない。

## 現行（2026-11 以降の実装）

* 軸 `interest_bearing_debt` は公開済み（`breakdown-interest-bearing-debt-v2`）。セルは `opening` / `closing`。**平均利率は持たない。** 行ごとに `source`・`maturity_class`・`in_total`・`excluded_reason`・`paired_row_index`・`source_tag`。
* notes の `borrowings_schedule` / `lease_liabilities` / `property_plant_equipment_schedule` / `goodwill_and_intangibles` は公開面から廃止。パーサは IBD / `fixed_assets` が使う。
* `per_share_information` / `issued_shares_and_capital` は notes に残す。
* 未公開の `sga_expense_breakdown` は対象外のまま（公開判断はオーナー管理のトラッカー Sheet）。

公開契約の正本は `docs/breakdown.md` / `docs/statement.md`。以下は 2026-10-10 の方針メモ。利率・リース列の当初案は、上の現行契約が勝つ。

## 全体方針

* 原本の再現は statement だけが担う。notes はできるだけ減らす。
* Breakdown に載せた種類は notes から廃止する。
* notes にしかない情報は、そのまま notes に残す（`per_share_information`、`issued_shares_and_capital` など）。
* **連結と単体**：連結がある会社は連結だけ、単体しかない会社は単体だけを見る。notes・明細表・有利子負債を含む全体の決まりにする。

公開 API の契約変更を含む作業は、着手前にオーナーの判断が必要（`docs/process/approvals.md`）。

## 新しい軸 `interest_bearing_debt`

* 社債・借入金（`borrowings_schedule`）とリース負債（`lease_liabilities`）を 1 つの軸にまとめる。移した後、notes のこの 2 種類は廃止する。
* 形は capex と同じく 1 行に複数の値を持たせる。当初候補は期首残高・期末残高・平均利率。**出荷は opening / closing。利率は持たない。**
* 行ごとに取得元の列を持たせる（`balance_sheet` / `borrowings_schedule` / `lease_note`。のちに `financials_bank_components`）。Jev が判断した行には監査記録を残す。

### 組み立て方

1. **抽出対象を絞る（コード）**：連結の BS、連結の借入金等明細表、IFRS のリース注記。単体しかない会社は単体の対応する表。
2. **各表から項目を選ぶ（Jev）**：「この行は有利子負債か」「リースの行か」を選択式で判定する。既存ルールどおり、確率 0.9 未満は採用せず要確認にする。
3. **二重計上の確認（コードを先に、決めきれないものを Jev に）**
   * コードで決めるもの：同じ表の合計と内訳の関係、金額が完全に一致する重複、既知の優先ルール。
   * Jev に聞くもの：金額が近いが一致しないものや、ラベルが違うもの。

### 実データから分かっていたこと（調査時点）

* **利率**：明細表の合計行の利率は、コード上で常に null。各行に利率が入るのは日本基準の明細表だけ。合計の利率を空欄にするか残高加重平均にするかは未決 → 出荷では持たない。
* **リース**：全社にあるのはリース負債の金額だけ。流動・非流動は開示区分があれば `maturity_class` に載せる（推定しない）。
* **リースの取得元**：注記、明細表のリース行、BS。`/financials` の有利子負債は軸の合計行。

## 関連して見つかった問題（軸の設計で対応する、と書いたもの）

* **ソニー（6758）**：`/financials` の有利子負債に長期借入金の非流動分が入っていない、という調査。タグを決め打ちで足すのではなく、Jev に候補を判断させる方針。
* **ソフトバンクグループ（9984）**：明細表の一部の表しか拾えていない、という調査。
* **トヨタ（7203）・日立（6501）**：IFRS の明細表にリース行があるのに、当時のリース負債 notes が `not_found`。notes を廃止するので notes 側は直さない。新しい軸が明細表のリース行を拾えることを確認項目にする。

残論点（合計行の利率、返済期限列、分母を `/financials` とそろえるか）のうち、返済期限は `maturity_class` として開示どおりに出荷。利率は持たない。
