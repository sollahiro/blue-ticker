# テストの層区分（Spec Asset方針）

言語が変わっても残る資産と、実装に紐づいて捨ててよい部分を区別する。新規・改修時の判断基準。

## 3層

| 層 | 内容 | 移行耐性 |
|---|---|---|
| **L0 Spec Asset** | 入出力・不変条件・契約・状態規則 | 残す |
| **L1 Spec Runner** | L0 を実行する薄い実行器 | 言語ごとに差し替え |
| **L2 Impl Coupling** | FW・内部型・呼び出し順 | 最小限。捨ててよい |

判定: **実装を消して仕様書だけで同じ合否が書けるか** → Yes なら L0。

## ケースラベル

| ラベル | 層 | 内容 |
|---|---|---|
| `SPEC_ORACLE` | L0 | 入力→出力の期待値 |
| `SPEC_INVARIANT` | L0 | 常に真であるべき関係 |
| `SPEC_CONTRACT` | L0 | REST/MCP の形・エラー意味 |
| `SPEC_POLICY` | L0 | version / skip / floor 等 |
| `HARNESS_ONLY` | L1 | 実行装置 |
| `IMPL_ONLY` | L2 | 実装内部都合のみ（新規禁止） |

smoke / golden は主に `SPEC_ORACLE` / `SPEC_INVARIANT`（`xbrl-parsing.md` §6）。

## 既知のギャップ

- 公開 note_type 8種はいずれも smoke 固定11社の外出しオラクル床に載済み（詳細は `xbrl-parsing.md` §6）
- `statement` 本体は `SmokeTests` 未通過（golden で smoke 社をカバー）
- 横断 `SPEC_INVARIANT`（financials↔statement↔notes↔breakdown）は薄い
- golden 期待値の多くがハードコード。外出しオラクルは一部 note_type / breakdown のみ

## 次の候補

- 横断 INVARIANT の追加
- ラベル混在テストファイルの分割要否
- golden ハードコードの外出し判断（都度）

## 方針

- 新規は L0 を厚く、L2 は最小
- 横断一貫性は結合テストではなく `SPEC_INVARIANT` として書く
- 外出し・フォルダ再編は都度優先度判断（全面移行はしない）
