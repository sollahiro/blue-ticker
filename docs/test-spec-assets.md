# テストの層区分（Spec Asset方針）

言語・フレームワークが変わっても残る資産と、実装に紐づいて捨ててよい部分を区別するための区分。新規テスト追加・既存テスト改修時の判断基準として使う。

## 3層

| 層 | 内容 | 移行耐性 |
|---|---|---|
| **L0 Spec Asset** | 入出力・不変条件・契約・状態規則そのもの。言語非依存 | 残す・厚くする |
| **L1 Spec Runner** | L0 を実行する薄い実行器（Swift Testing 等） | 言語ごとに差し替え前提 |
| **L2 Impl Coupling** | FW・内部型・配線・実行順など実装内部都合 | 最小限。捨ててよい |

判定基準: **実装を消して仕様書だけで同じ合否が書けるか** → Yes なら L0。

## ケースラベル

新規テストを書く／既存テストを見直す際、どのラベルに該当するか意識する（機械的な付与は必須ではない）。

| ラベル | 内容 | 例 |
|---|---|---|
| `SPEC_ORACLE` | 入力→出力の期待値（数値・行・docID） | `smoke/`, golden回帰の期待値 |
| `SPEC_INVARIANT` | 常に真であるべき関係 | 貸借一致、内訳合計＝合計値、waterfall因子和＝Δ |
| `SPEC_CONTRACT` | REST/MCP の JSON schema・エラー意味 | レスポンス型、エラーコード |
| `SPEC_POLICY` | version/skip/floor/優先順位などの状態規則 | ingest の再計算トリガー表（`versioning.md`） |
| `HARNESS_ONLY` | 上記を走らせるための装置 | テストヘルパー・fixture ローダー |
| `IMPL_ONLY` | 今の実装内部都合のみを見ている | 呼び出し順・内部 mock の検証（廃棄候補） |

`SPEC_ORACLE` / `SPEC_INVARIANT` は smoke・golden 回帰（`xbrl-parsing.md` §6）の言語非依存版に相当する。`SPEC_INVARIANT` はモジュール間の一貫性（横断整合性）を、特定の実装配線ではなく述語として表現する点が従来の統合テストと異なる。

## 既知のギャップ

- smoke の床（§6.2 固定企業セット）が note_type(statement-notes) / breakdown の決定論ロジックを未カバー（golden回帰のみ）
- financials ↔ statement ↔ notes ↔ breakdown を横断する `SPEC_INVARIANT` がスイートとして薄い
- golden回帰の期待値は `RealXbrl*Tests.swift` にハードコードされており、データとして外出しされていない

## 方針

- 新規テストは L0（`SPEC_ORACLE` / `SPEC_INVARIANT`）を厚くすることを優先し、L2 は最小限に留める
- 横断的な一貫性チェックは、特定モジュールの結合テストではなく `SPEC_INVARIANT`（言語非依存の述語）として書く
- golden期待値の外出し・棚卸し・フォルダ再編は本方針が固まった後の実務課題（優先度は都度判断）
