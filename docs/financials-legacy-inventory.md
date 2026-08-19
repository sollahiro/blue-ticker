# financials 組立置換後のレガシー棚卸し

`financials`（`company_financials`）は維持しつつ、値の由来を `statement/notes/breakdown` 正本へ寄せた後の棚卸し。

## 結論

- **本番経路に未参照の完全デッドコードは限定的**。
- 旧実装由来の命名・モジュール（特に `Extractors.swift`）は残るが、現時点では resolver 群から参照されており削除不可。
- テスト専用の比較コード（旧経路）は残存しているが、回帰検知の役割がある。

## 参照の実態（2026-08-19時点）

### 1) financials 本流（現役）

- `IndividualAnalyzer` は `StatementFinancialsResolver.resolve` を主軸に使用。
- 補完として `StatementNotesResolver.financialsCanonical*` と `BreakdownFinancialsResolver.financialsCanonical*` を使用。
- IBD は `IBDExtractor.extractCanonical` を使用（旧 `extract` ではない）。

このため「組立の由来」は `statement/notes/breakdown` 側へ寄っている。

### 2) レガシー見えするが現役の層

- `Extractors.swift` 配下の抽出器（`IncomeStatementExtractor` など）は、`StatementFinancialsResolver` / `BreakdownFinancialsResolver` / `StatementNotesResolver` から参照される。
- `USGAAPHtml` は `USGAAPStatementHtml` とは役割が別だが、strip/mapping 補助として `StatementFinancialsResolver` 内で利用される。

よって「古い実装に見えるが依存先あり」であり、一括削除すると現行経路を壊す。

### 3) テスト専用の旧比較経路

- `extractFromXBRL(...)` は `SwiftTests/BlueTickerTests/Spec/Oracle/SmokeTests.swift` のみで使用。
- `IBDExtractor.extract(...)`（non-canonical 側）も `SmokeTests` / `IBDExtractorTests` /
  `CrossModuleInvariantTests` で比較・不変条件検証に使用。
- 本番ソース `Sources/` には呼び出しが無く、可行性比較・回帰監視のためのテスト専用資産。

## cleanup 候補（段階的）

1. `Extractors.swift` の「financials 直接抽出」印象を弱める命名再編（例: resolver 内部依存として責務を明示）。
2. `StatementFinancialsResolver` が依存する抽出器を最小API化し、未使用抽出器を検出しやすくする。
3. smoke 比較コードは維持しつつ、目的コメントを明示して「本番経路ではない」ことを固定化する。

## 今回の判断

- `company_financials` は配信面（Summary/Waterfall）の materialized view として維持。
- したがって当面は「削除」より「責務明確化と縮退可能性の可視化」を優先する。
