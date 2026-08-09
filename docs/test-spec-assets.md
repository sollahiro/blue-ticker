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

新規テストを書く／既存テストを見直す際、どのラベルに該当するか意識する。

| ラベル | 層 | 内容 | 例 |
|---|---|---|---|
| `SPEC_ORACLE` | L0 | 入力→出力の期待値（数値・行・docID） | `smoke/`, golden回帰の期待値 |
| `SPEC_INVARIANT` | L0 | 常に真であるべき関係 | 貸借一致、内訳合計＝合計値、waterfall因子和＝Δ |
| `SPEC_CONTRACT` | L0 | REST/MCP の JSON schema・エラー意味 | レスポンス型、エラーコード |
| `SPEC_POLICY` | L0 | version/skip/floor/優先順位などの状態規則 | ingest の再計算トリガー表（`.agents/rules/project/versioning.md`） |
| `HARNESS_ONLY` | L1 | 上記を走らせるための装置 | テストヘルパー・fixture ローダー |
| `IMPL_ONLY` | L2 | 今の実装内部都合のみを見ている | 呼び出し順・内部 mock の検証（廃棄候補。新規に追加しない） |

`SPEC_ORACLE` / `SPEC_INVARIANT` は smoke・golden 回帰（`xbrl-parsing.md` §6）の言語非依存版に相当する。`SPEC_INVARIANT` はモジュール間の一貫性（横断整合性）を、特定の実装配線ではなく述語として表現する点が従来の統合テストと異なる。

全 `@Test` へキーワードヒューリスティックで仮ラベルを機械付与したスナップショットが [test-spec-inventory.md](test-spec-inventory.md) にある（下記「進捗」参照）。

## 既知のギャップ

- smoke の床が **他 note_type**（`borrowings_schedule` 以外）/ breakdown の決定論ロジックを未カバー（詳細・経緯は `xbrl-parsing.md` §6。`borrowings_schedule` は 2026-08-09 に smoke 11社を外出しオラクルへ追加済み）
- `statement`（Statement 取り込み本体、`StatementAnalyzer`/`StatementClassifier`）は smoke（`SmokeTests.swift`）を一切通らない（対象は `Extractors.swift` 経由の基本財務諸表抽出器のみ）。2026-08-09、smoke固定11社のうち US-GAAP2社（元々 `notApplicable` として別途カバー済み）を除く**9社全件**の golden を `RealXbrlStatementTests.swift` へ追加（既存の Toyota/Denso/Nintendo 3社に足す形）。ただし `SmokeTests.swift` 本体には未統合（別ファイルの golden 追加に留まる）
- financials ↔ statement ↔ notes ↔ breakdown を横断する `SPEC_INVARIANT` がスイートとして薄い（borrowings_schedule の1本のみ追加済み。他の組み合わせは未着手）
- golden回帰の期待値は大半が `RealXbrl*Tests.swift` にハードコードされたまま（borrowings_schedule は外出しオラクルあり: 試作3docID + smoke 11社。ハードコード golden は深さ用に併存）
- 機械付与ラベルの62%が UNCLASSIFIED（[test-spec-inventory.md](test-spec-inventory.md)）。キーワードヒューリスティックの限界で、手動レビューが必要

## 進捗（2026-08-09）

方針策定後、以下を実装・検証した。

| 内容 | 状態 |
|---|---|
| 全 `@Test` への仮ラベル機械付与（棚卸し表） | 完了。[test-spec-inventory.md](test-spec-inventory.md)（1054件、UNCLASSIFIED 62%） |
| golden 期待値の外出しフォーマット（1 note_type） | 完了・拡張。borrowings_schedule（試作3docID + smoke固定11社、`StatementNotesOracleFormatTests.swift`）。他 note_type への本移行は未着手 |
| smoke 床への note_type 追加 | 部分完了。`borrowings_schedule` のみ（US-GAAP 2社は `not_applicable`）。他 note_type / breakdown は未 |
| statement 側 golden への smoke企業セット追加 | 完了。US-GAAP2社除く9社全件（味の素/ニチレイ/AZplanning/オークマ/クボタ/スズキ/東邦レマック/三菱UFJ/三井住友）を `RealXbrlStatementTests.swift` へ追加。「同一区分内で他行の components から参照されない isTotal 行＝各区分の最上位合計」という構造的規則で機械的に特定し、`smoke_expected/*.json` の既存 golden 値（total_assets/net_assets/sales/cfo/cfi）と突合して確定。テスト側もこの構造規則を実行時に適用する `expectBalanceSheetIdentity` invariant として実装（固定値の再掲ではない） |
| 横断 `SPEC_INVARIANT` の追加（例: IBD vs borrowings_schedule） | 完了（`CrossModuleInvariantTests.swift`）。`IBDExtractor.extract` を実際に呼び、method="borrowings_schedule" で解決した docID は明細表合計との一致を、method="field_parser" の docID（SOMPO S100R1LR）は一致しないこと自体を実データ値で検証する |
| ラベルに応じたサブフォルダ移動 | 部分完了。単一ラベルが7割以上を占め、かつ非UNCLASSIFIEDなファイル25件を機械的基準で移動、加えて上記2件（試作・横断INVARIANT自体）を著者判断で追加し、計27件を `SwiftTests/{BlueTickerTests,BltServerCoreTests}/Spec/{Oracle,Invariant,Contract,Policy}/` へ移動。ラベル混在ファイル（例: `StatementContractTests.swift`）とUNCLASSIFIED優勢ファイルは元の場所のまま |

## 次の候補（未着手）

- 機械付与ラベルの精度向上（UNCLASSIFIED 62%の低減、または手動レビューでの上書き）
- golden外出しフォーマットを他 note_type・他ロジックへ本移行するかの判断
- 横断 `SPEC_INVARIANT` の追加（financials ↔ statement ↔ notes ↔ breakdown の他の組み合わせ）
- ラベル混在ファイルの扱い（分割するか、複数ラベル対応のまま残すか）

## 方針

- 新規テストは L0（`SPEC_ORACLE` / `SPEC_INVARIANT`）を厚くすることを優先し、L2 は最小限に留める
- 横断的な一貫性チェックは、特定モジュールの結合テストではなく `SPEC_INVARIANT`（言語非依存の述語）として書く
- golden期待値の外出し・棚卸し・フォルダ再編は実務課題として都度優先度判断する（現状は上記「進捗」の範囲のみ実施済み、全面移行はしていない）
