# テスト資産の分類方針（Spec Asset）

Swift → 他言語移行を見据えたとき、移行後も残る価値を持つのはテストコードそのものではなく、
**言語非依存の仕様資産（Spec Asset）**である。この前提でテストの重心を移す。

## 3層構造

```
L0 Spec Asset     … 言語非依存。残す・厚くする
L1 Spec Runner    … 薄い実行器。言語ごとに差し替え可能
L2 Impl Coupling  … FW/内部型/配線への結合。捨ててよい・最小に保つ
```

移行時に書き直すのは L1/L2 のみ。L0（期待値・関係式・契約・規則）はそのまま移植できることを目指す。

## ラベル

各 `@Test` は次のいずれかに分類できる。判定基準は「実装を消して仕様書だけで同じ合否が書けるか」→ Yes なら `SPEC_*`。

| ラベル | 定義 | 例 |
|---|---|---|
| `SPEC_ORACLE` | 入出力の期待値照合 | `smoke_expected/` の年次期待値JSON、`breakdown_extraction_expected.json` |
| `SPEC_INVARIANT` | 実装によらず常に真であるべき関係式 | `WaterfallDecompositionTests.opChangeFactorsSumToDelta`（分解要素の合計が差分と一致） |
| `SPEC_CONTRACT` | REST/MCP/JSON の公開契約 | `StatementContractTests.responseRoundTripsThroughSnakeCaseJson`（round-trip 保証） |
| `SPEC_POLICY` | version/skip/floor 等の状態遷移規則（表駆動） | `StatementContractTests.isServableUsesNumericFloorNotLexicographicOrder` |
| `HARNESS_ONLY` | 実行基盤（キャッシュ準備・フィクスチャ）のみで仕様を持たない | `SmokeCacheSupport.swift` |
| `IMPL_ONLY` | FW/内部型/呼び出し順など実装結合。廃棄候補 | — |

ラベルはコードへの機械的付与（次段 B）までは概念上の区分として使い、レビュー・新規テスト設計時の判断軸とする。

全 `@Test` への仮ラベル機械付与スナップショットは [test-spec-inventory.md](test-spec-inventory.md)。

## 現状ギャップ

1. smoke の床（[xbrl-parsing.md §6](xbrl-parsing.md#6-スモークテスト)）が note_type/breakdown の決定論ロジックを未カバー（golden のみ）
2. financials ↔ statement ↔ notes ↔ breakdown の横断 `SPEC_INVARIANT` がスイートとして薄い（D で borrowings_schedule の1本のみ追加。他の組み合わせは未着手）
3. geography 等の期待JSONが回帰に未接続
4. 仮ラベルの62%が UNCLASSIFIED（[test-spec-inventory.md](test-spec-inventory.md)）。キーワードヒューリスティックの限界で、手動レビューが必要

## 進捗（2026-08-09、A〜D 完了・E 部分完了）

| # | 内容 | 状態 |
|---|---|---|
| A | 本方針を docs/ へ固定（本ファイル） | 完了 |
| B | 全 `@Test` へ仮ラベルを機械付与した棚卸し表を作る | 完了。[test-spec-inventory.md](test-spec-inventory.md)（1054件、UNCLASSIFIED 62%） |
| C | golden 期待値の外出しフォーマットを1 note_type/statement で試作する | 完了。borrowings_schedule・3docIDのみ（`StatementNotesOracleFormatTests.swift`）。他 note_type への本移行は未着手 |
| D | 横断 `SPEC_INVARIANT` を1本設計・追加する（例: IBD vs borrowings_schedule） | 完了（`CrossModuleInvariantTests.swift`。IBDExtractor.extract を実際に呼び、method="borrowings_schedule" で解決した docID は明細表合計との一致を、method="field_parser" の docID（SOMPO S100R1LR）は一致しないこと自体を検証する） |
| E | ラベルに応じたサブフォルダ移動 | 部分完了。単一ラベルが7割以上を占め、かつ非UNCLASSIFIEDなファイル25件を機械的基準で移動。加えて C・D で新規作成した2件（`StatementNotesOracleFormatTests.swift` は機械ラベルではUNCLASSIFIEDだが著者判断でOracleへ、`CrossModuleInvariantTests.swift` はSPEC_INVARIANTへ）を手動で追加し、計27件を `Spec/{Oracle,Invariant,Contract,Policy}/` へ移動。ラベル混在ファイル（例: `StatementContractTests.swift`）とUNCLASSIFIED優勢ファイルは元の場所のまま |

## 次の候補（未着手）

- B の再実行によるラベル精度向上（UNCLASSIFIED 62%の低減、または手動レビューでの上書き）
- C のフォーマットを他 note_type・他ロジックへ本移行するかの判断
- D と同型の横断 `SPEC_INVARIANT` の追加（financials ↔ statement ↔ notes ↔ breakdown の他の組み合わせ）
- E のラベル混在ファイルの扱い（分割するか、複数ラベル対応のまま残すか）

## 適用ガイド

新規テスト追加時・既存 smoke/golden 改修時は、追加するテストがどのラベルに当たるかを意識する。
`IMPL_ONLY`（呼び出し順・内部構造の検証）は追加しない（`.agents/rules/generic/workflow.md`「テスト名」参照）。
