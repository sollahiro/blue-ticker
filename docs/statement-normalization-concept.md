# 財務諸表完全正規化の構想（Stage 7 / Stage 8）

有価証券報告書 XBRL の BS/PL/CF を、絞り込みなしで構造化して返す機能（Statement）の設計メモ。
関連: Summarize/Analyze（`docs/feature-tiers.md`）は絞り込み指標、Breakdown（Stage 6、
`docs/breakdown-normalization-concept.md`）は事業別・地域別売上の意味正規化。Statement は
どちらとも異なり「開示された全項目を、企業間の科目統一を試みず、忠実に構造化する」ことが本体。

## 目的

| 機能 | 提供価値 | 対象範囲 |
|---|---|---|
| Summarize / Analyze | 絞り込んだ主要指標（売上・利益・ROE 等 ~20 項目） | `Extractors.swift` の**固定タグリスト** |
| Breakdown | 事業別・地域別売上の**企業間比較用**正規化スナップショット | セグメント注記・地域注記のみ |
| **Statement**（本構想） | 開示された BS/PL/CF の**全項目**をそのまま構造化 | XBRL 全 fact（標準タグ＋企業拡張タグ） |

Statement は「その企業自身の財務諸表を漏れなく構造化して見せる」ことが目的であり、
Breakdown のような「企業間で表記が不揃いな項目を共通スキーマへ意味的に写像する」問題ではない。
科目名の企業間統一（例:「その他流動資産」の表記ゆれ吸収）は非ゴール。

## 抽出方式（決定論のみ、LLM 不要）

既存の `XBRLUtils.collectAllNumericFacts`（`Sources/BlueTicker/Analysis/XBRLUtils.swift:277`）が
XBRL ディレクトリ内の**全数値 fact**を、以下のメタデータ付きで既に汎用抽出できている。

- **`label`**: label linkbase（`loadLabelsByTag`, 同ファイル 195 行目）由来。標準タグだけでなく
  **企業拡張タグ（company extension）もラベル欠落なし**（拡張タグは企業の XBRL パッケージ自身が
  label linkbase を同梱するため）
- **`role`/`roles`**: presentation linkbase（`loadRolesByTag`, 同ファイル 219 行目）由来の roleURI。
  どのタグがどの財務諸表（BS/PL/CF）に属するかは、この roleURI から機械的に決まる
- **`filterFactIndexBySections`**（同ファイル 310 行目）で role/section を条件に fact index を
  絞り込む既存関数があり、BS/PL/CF への振り分けにそのまま使える

Duration（PL・CF）/Instant（BS）の判定、連結／非連結コンテキストの判定は
`Analysis/FieldParser.swift`・`Analysis/ContextHelpers.swift` の既存ロジックを流用する
（`.agents/rules/project/xbrl-analysis.md` の「コンテキスト判定は共通化しない」方針通り、
新規に書き直さない）。

**Breakdown（Stage 6）で LLM が必要だった理由との対比**: Breakdown のセグメント注記・地域注記は
「企業ごとに構成が不揃いな自由形式 HTML 表」を人間が読む前提で開示されており、軸判定・変則表の
解釈に意味理解が要る。一方 BS/PL/CF は XBRL 標準タクソノミの presentation linkbase で構造
（どの財務諸表のどこに属するか）が標準化されている。**タグ抽出＋linkbase メタデータの機械的な
組み立てで完結し、LLM によるフォールバックは不要**と判断する。

### 実データ検証（2026-07-29、キャッシュ済み実 XBRL 158社）

対象は日経225限定で実装する（Stage 6 と同じ `assets/nikkei225.csv` / `priorityIngestCodes()` を
流用。Stage 6 は LLM 費用抑制が理由だったが、Stage 7 はまず対象を絞って検証コストを下げる目的）。

ローカルにキャッシュ済みの実 XBRL 158社分に対し `collectAllNumericFacts` を実行し、
role URI の末尾セクション名（`sectionNameFromRole`）の分布を確認したところ、
J-GAAP/IFRS 問わず以下のキーワード判定に収束することを確認した（`Analysis/StatementClassifier.swift`
として実装済み）。

| 会計基準 | BS | PL | CF |
|---|---|---|---|
| J-GAAP | `BalanceSheet` / `ConsolidatedBalanceSheet` | `StatementOfIncome` / `ConsolidatedStatementOfIncome` | `StatementOfCashFlows-indirect` / `ConsolidatedStatementOfCashFlows-indirect` |
| IFRS | `ConsolidatedStatementOfFinancialPositionIFRS` | `ConsolidatedStatementOfProfitOrLossIFRS` | `ConsolidatedStatementOfCashFlowsIFRS` |

検証で分かった注意点（キーワードリストは `Constants/Xbrl.swift` に実装済み）:

1. **`Notes` 接頭辞のロールを先に除外する必要がある** — `NotesConsolidatedBalanceSheet` のような
   注記系ロールにも `"BalanceSheet"` という文字列が含まれるため、単純な部分一致だけだと注記
   （Stage 8 対象）が本体に混入する。`StatementClassifier.classify(role:)` は判定の入口で
   `Notes` 接頭辞を除外する
2. **連結優先・非連結フォールバックが実際に必要** — 158社中ほとんどは `Consolidated*` ロールを
   持つが、9社ほどは `Consolidated` が付かないロールしか持たない（子会社を持たない小規模企業。
   Breakdown Stage 6 の学びと同型）。ただし連結/非連結の判定自体は role 名ではなく
   **contextRef**（`ContextHelpers.isConsolidatedInstant/Duration`）で行う。非連結側は
   `isNonConsolidatedInstant/Duration` ではなく `isPureNonConsolidatedContext`（完全一致）を使う
   — 前者は `_NonConsolidatedMember` に続けてセグメント軸メンバーが付いた dimensioned context も
   部分一致で拾ってしまい、同一タグにセグメント別の値が複数紐づく事故になるため（監査で指摘・
   `StatementClassifierTests.nonConsolidatedFallbackExcludesSegmentDimensionedContexts` で回帰）

未検証事項: 銀行・保険等の特殊タクソノミを持つ会社が今回の158社サンプルに含まれているかは
未確認（Breakdown Stage 6 では銀行が別経路を要した理由は「指標タグが別概念」であり構造自体が
崩れたわけではないため、Statement は「そのまま出す」設計上は影響を受けにくいと考えられるが、
実際の日経225銀行株での検証は未実施）。

## 公開面設計（free / paid 分離）

`docs/feature-tiers.md` の既存ルール:

> 機能の課金境界はエンドポイント・ツール単位で決める（フィールド単位のマスキングではない）

本体（BS/PL/CF）を無料、注記（notes）を有料にする場合、Breakdown の `axis=business|geography`
のような**同一エンドポイント内のクエリパラメータ分岐では課金境界を満たせない**（両軸とも同じ
ティアだから成立していた設計であり、ティアを分けたい場合の前例にはならない）。

Summarize/Analyze と同型の**別エンドポイント・別ツール**分割を採用する。

| 機能 | REST | MCP | Stage | 想定ティア |
|---|---|---|---|---|
| Statement（本体） | `GET /v1/companies/{code}/statement` | `get_statement` | Stage 7 | 無料想定 |
| Statement Notes（注記） | `GET /v1/companies/{code}/statement/notes` | `get_statement_notes` | Stage 8 | 有料想定 |

両者は別テーブル・別 ingest ステージとして設計する（本体は決定論のみで完結するが、注記は
Stage 6 同様 LLM フォールバックが必要になる可能性が高く、staleness・再計算方針が本体と異なる
ため。詳細は「Stage 8（今後）」参照）。

## 抽出の実装（今回追加）

- `Analysis/StatementClassifier.swift`: role → BS/PL/CF 判定（`classify(role:)`）と、
  fact index から指定 section type の当期・連結優先／非連結フォールバック行を抽出する
  `extractLineItems(from:sectionType:)`。表示順は presentation linkbase の並び順を
  取得できないため、暫定でタグ名のアルファベット順を採用（「未決事項」参照）
- `Services/StatementAnalyzer.swift`: 単一書類（docID）の XBRL をダウンロードし、要求された
  statement type だけを `StatementClassifier` で抽出して `StatementYear` を返す。
  `IndividualAnalyzer`（Stage 4）と異なり複数年度の履歴集約は行わない（1書類＝1年度分のみ）
- `Server/BltServerFacade.swift` の `extractStatement(docID:statementTypes:)`:
  Stage 5 の `extractFilingSections(docID:)` と同型の facade メソッド。現時点では
  ingest からの呼び出しはなく、DevCLI からのみ呼ばれる
- `DevCLI/DevStatementCommand.swift`（`ticker-dev statement <code> [docID] --bs --pl --cf`）:
  目視確認用の開発コマンド。`--bs`/`--pl`/`--cf` は**少なくとも1つ必須**（未指定はエラー。
  「指定なしで全部返す」という暗黙動作にしない）

## データモデル（今回追加した契約型の骨組み）

`Sources/BlueTicker/Models/StatementContract.swift` に、`FinancialsContract.swift` と同型の
バージョニング四点セット（`statementCacheVersion` / `statementMinServableVersion` /
`statementCacheVersionNumber(_:)` / `isServableStatementCacheVersion(_:)`）と、
`StatementResponse` / `StatementYear` / `StatementLineItem` の Codable 契約を定義した。

```text
StatementResponse
  schema_version, code, name, sector, market
  years: [StatementYear]

StatementYear
  fy_end, financial_period, doc_id
  balance_sheet:     [StatementLineItem]
  income_statement:  [StatementLineItem]
  cash_flow:         [StatementLineItem]

StatementLineItem
  tag, label, value, unit, order
```

`StatementComputeResult`（`.success` / `.notApplicable` / `.failed`）は `FinancialsComputeResult`
と同じ3値パターン（`.agents/rules/project/error-handling.md`）に合わせた。

DB モデル・ingest・REST・MCP からはまだ呼ばれない（DevCLI からのみ呼ばれる。下記参照）。

## Stage 番号とロードマップ上の位置づけ

- **Stage 7（本体・BS/PL/CF）**: 抽出ロジック（`StatementClassifier`/`StatementAnalyzer`）と
  DevCLI での目視確認まで実装済み。DB モデル・ingest・REST・MCP 配線は未着手。
- **Stage 8（注記）**: 構想のみ。対象注記・正規化方式（LLM 要否含む）は未確定。

## 今回のスコープ外（非ゴール）

- DB モデル・マイグレーション・`Stage7Ingest.swift`・REST ルート・MCP ツール配線
- 複数年度の履歴集約（`EdinetDiscovery` を使った複数書類の走査。現状は単一書類＝単一年度のみ）
- 注記（Stage 8）の抽出方式・対象注記の確定・LLM 要否判断
- 企業拡張タグの正規化ポリシー（そのまま出すか、正規化するか）の確定
- 企業間の科目名統一（Breakdown 的な意味正規化）

## 未決事項（Stage7Ingest 実装時に詰めること）

1. **企業拡張タグの識別**: 契約に「標準タグか拡張タグか」を示すフラグを持たせるか。今回の
   `StatementLineItem` には未実装（`tag` 文字列のみ）
2. **`order`（表示順）の取得方法**: presentation linkbase は「どの role に属するか」は
   `loadRolesByTag` で取れるが、**role 内の並び順（プレゼンテーション順）は現状どの既存関数も
   保持していない**。`StatementClassifier.extractLineItems` は暫定でタグ名のアルファベット順を
   採用している。真の表示順対応には `PresentationLinkbaseParser`（`XBRLUtils.swift` 内）の拡張が
   必要
3. **複数年度の履歴集約**: `StatementAnalyzer` は単一書類のみ対応。`stage5IngestYears`（6年）を
   使った複数書類の走査・マージは Stage7Ingest 実装時に追加する
4. **半期報告書への対応要否**: 通期のみか、`company_half_financials` 同様に半期も対象にするか（今回は保留・通期のみ）

## 関連ドキュメント

- `docs/feature-tiers.md` — Statement の境界（free/paid 分離方針）
- `docs/breakdown-normalization-concept.md` — Stage 6（対比: LLM が必要になった理由）
- `docs/blt-server-roadmap.md` — Stage 7/8 の索引ポインタ
- `.agents/rules/project/xbrl-analysis.md` — `XBRLUtils` 共通関数の使用規約
- `.agents/rules/project/versioning.md` — cache_version / min_servable の運用規則
