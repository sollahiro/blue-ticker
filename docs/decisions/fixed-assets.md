# 固定資産表 breakdown 軸 `fixed_assets` の契約

出典: 旧課題管理のチケット（移行日 2026-11-12）。当時の題名: 固定資産表 breakdown 軸 `fixed_assets` の方針（PPE・無形・のれん／v1 は closing・取得原価・累計額）。
この文書は決定・契約の正本としてリポジトリで維持する。件数や進捗の最新値はここに書かない。

## 現行（2026-11 以降の実装）

軸 `fixed_assets` は公開済み。旧軸 `property_plant_equipment` / `goodwill_and_intangibles` と、notes の同名 note_type は公開面から廃止（404）。契約の正本は `docs/breakdown.md` と `BreakdownContract.swift`。

出荷した v1 は、元チケット案の「列 = closing / acquisition_cost / accumulated_depreciation」ではなく **正味帳簿価額（`amount`）** である。

* 行 = 開示されたクラス。`label` は有報の日本語。行ごとに `asset_class`（`property_plant_equipment` / `intangible_assets`。のれんは無形に含む）と `source_tag`。
* IFRS は連結の注記（有形固定資産、のれん及び無形資産）。日本基準は連結 BS の区分科目（計算リンクの内訳）。内訳は正味なので、取得原価と減価償却累計額は行にしない。米国基準は `not_found`。
* payload の `property_plant_equipment` / `intangible_assets` は区分ごとの合計。`denominator` は開示された区分合計の和。
* 報告セグメント別ののれんは軸 `goodwill` に残す（責務を分ける）。

以下は元チケットの方針メモ（調査時点）。列セットや `category_group: goodwill` の独立は、上の現行契約が勝つ。

## 位置づけ（調査時点の方針）

* 固定資産表（有形・無形・のれんのクラス別）は **breakdown 軸**にする。Notes にはしない（純粋な原本抽出ではないため）。
* J-GAAP は **連結 BS（Statement）を正本**にする。IFRS は `jpigp_cor` の Instant タグ。
* 既存の Notes `property_plant_equipment_schedule` と `goodwill_and_intangibles`、軸 `equity_method_investments`（分析価値が低い）は、新軸の後に廃止する候補、と書いた。equity_method は 2026-11 に `segment` 行のセルへ統合して廃止済み。

## 契約（調査時点に決めたこと。現行との差は冒頭）

* 行 = 開示されたクラス。`label` は有報の日本語。
* 列の当初案: `closing`、`acquisition_cost`、`accumulated_depreciation`（累計額は負値のまま）。**出荷 v1 は正味 `amount` のみ。**
* `opening` **は v1 に持たない**（前年の期末と同値で情報が増えない）。期首と増減は後続で足す、という案はそのまま未着手。
* 欠測セルは null。クラス別の純額がタグ付けされていない会社（トヨタ等）は null のまま。**取得原価−累計額で作らない**（差し引きで値を作らない原則）。
* `row_kind`: `EntityTotal` は **有形固定資産・無形固定資産・のれん(IFRS のみ)** の3つだけ、という案。出荷は区分合計を payload キーに持ち、のれんは無形に含める。
* 検証: クラス合計とタグ付き合計の突合せは **チェックのみ**。丸め（百万円単位の数単位）は許容、それより大きい差だけ `needs_review`。差を埋める「その他」行は作らない。
* **行の基準は連結 BS の行**。Instant `Goodwill` タグの有無だけで行を出さない（大隈は Instant `Goodwill` があるが BS の行ではない）。
* 負ののれんは BS 残高がなく損益のみ → 行に含めない。
* クラス名は会社ごとに違う前提。

## のれんと `goodwill` 軸の責務

* 連結のれん（クラス）は `fixed_assets`、セグメント別の内訳は `goodwill` 軸に残す（責務を分ける）。
* `goodwill` と `goodwill_amortization` の統合は **セグメント軸の中**で進める。固定資産軸には集約しない。`goodwill_amortization` は `goodwill` の `amortization` セルへ統合済み。

## 3社サンプルの確認結果（調査）

* IFRS 味の素 S100VXJA: 有形・無形・のれんの closing/取得原価/累計額がそろう。合計との丸め差 1〜3 百万円。
* IFRS トヨタ S100VWVY: クラス別 closing は null、合計行と取得原価・累計額あり。
* J-GAAP 任天堂 S100W73A: のれんなし。親会社の附属明細表（123,082）は連結（112,612）と別物で混ぜない。
* J-GAAP 横河 S100VY8X / ニチレイ S100VYA0 / 名鉄 S100W4F4: のれんは連結 BS の無形固定資産の内訳。クラス+のれん と 無形合計 の差は 1〜2 百万円以内（ニチレイは一致）。

## 残作業

取得原価・累計額列、IFRS の HTML 増減表、J-GAAP 附属明細表は未着手。期待値（golden）は構造的に特別なケースだけ足す（任天堂の附属明細表と連結の差、大隈の Instant Goodwill、名鉄の負ののれん）。進捗はオーナー管理のトラッカー Sheet。
