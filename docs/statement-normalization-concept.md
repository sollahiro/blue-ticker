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
  `extractLineItems(from:sectionType:)`。表示順は presentation linkbase の実際の並び順
  （`XBRLUtils.loadPresentationOrder` / `XbrlFact.orderByRole`）を使い、取得できないタグは
  タグ名のアルファベット順へフォールバックする（2026-07-30、「実装方針」3 で確定）
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

2026-07-29 に DB モデル（`company_statements`）・ingest（`Stage7Ingest.swift`）・REST
（`GET /v1/companies/{code}/statement`）・MCP（`get_statement`）配線を実装し、使い捨て Neon
への実 EDINET 取り込み・REST/MCP 読み出しまで検証済み（下記「実装方針」参照）。

## Stage 番号とロードマップ上の位置づけ

- **Stage 7（本体・BS/PL/CF）**: 抽出ロジック（`StatementClassifier`/`StatementAnalyzer`）と
  DevCLI での目視確認は実装済み（PR #153）。DB モデル・ingest・REST・MCP 配線も
  下記「実装方針」に沿って実装済み（2026-07-29、対象は日経225限定でスタート。使い捨て Neon
  への実データ書き込み・読み出しまで検証済み）。日経225全社への本番ingestはこれから
  （`assets/nikkei225.csv` を持つ本番/ローカル環境で `blt-server ingest --stages 7` を実行）。
- **Stage 8（注記）**: 構想のみ。対象注記・正規化方式（LLM 要否含む）は未確定。

## 今回（PR #153）のスコープ外（非ゴール）

PR #153（抽出ロジック・DevCLI）時点の切り分け。~~取り消し線~~の項目は下記「実装方針」で実装済み。

- ~~DB モデル・マイグレーション・`Stage7Ingest.swift`・REST ルート・MCP ツール配線~~ → 実装済み（下記「実装方針」参照）
- ~~複数年度の履歴集約~~ → `Stage7Ingest` が `stage5Candidates` の docID 反復で対応済み（下記「実装方針」2）
- 注記（Stage 8）の抽出方式・対象注記の確定・LLM 要否判断
- 企業拡張タグの正規化ポリシー（そのまま出すか、正規化するか）の確定
- 企業間の科目名統一（Breakdown 的な意味正規化）

## 実装方針（Stage7Ingest/DB/REST/MCP 着手時に確定、2026-07-29）

PR #153 時点の「未決事項」を次のとおり確定した。DB モデル・`Stage7Ingest.swift`・REST・MCP は
本方針に沿って実装する。

1. **対象母集団**: **日経225限定**（Stage 5/6 と同じ `assets/nikkei225.csv` /
   `priorityIngestCodes()` を流用）で開始する。Stage 7 は LLM を使わないためコスト制約はないが、
   実データ検証が158社（ほぼ日経225相当）に留まり、銀行・保険等の特殊タクソノミでの検証が
   未実施（上記「未検証事項」参照）。母集団拡大（全銘柄化）はこのリスクを解消したうえで
   `docs/blt-server-roadmap.md` の TODO に別項目として積む
2. **複数年度の履歴集約**: `StatementAnalyzer` 自体は単一書類のみのままでよい。`Stage7Ingest` は
   Stage 6 と同じく `stage5Candidates`（`listedCodes × 有報(120) × 直近 stage5IngestYears 件`）を
   再利用し、返ってきた **docID ごとに `StatementAnalyzer.extract` を1回ずつ呼んで1行として
   upsert** する（`CompanyBreakdown` と同じ「1書類=1行」設計）。複数年度対応は
   `StatementAnalyzer` の拡張ではなく ingest 側の候補選定の繰り返しで自然に達成されるため、
   追加のマージロジックは不要
3. **`order`（表示順）**: v1 のうちに真の表示順対応を実装した（2026-07-30。本番に
   `company_statements` の行がまだ0件だった＝バージョンバンプの移行コストが実質ゼロだった
   ため、`statement-v2` を切らず v1 のまま拡張した。`.agents/rules/project/versioning.md`
   の「抽出ロジック変更時にバンプ」原則より、移行コストを判断材料に優先した）。
   `Analysis/XBRLUtils.swift` の `PresentationLinkbaseParser` を拡張し、`<loc>`
   （xlink:label→タグ）と `<presentationArc>`（from/to/order）から role ごとの木を構築、
   深さ優先で辿った通し番号を `XbrlFact.orderByRole[role]` として持たせる
   （`XBRLUtils.loadPresentationOrder(in:)`）。`StatementClassifier.extractLineItems` は
   sectionType に分類される role のうち、実際に採用された（連結優先／非連結フォールバック後の）
   タグ集合を最も多くカバーする role を「代表 role」として1つに固定し（`primaryRole`）、
   その role の order のみを使う。

   **学び1**: 表示順は同一 role（presentation tree）内でしか比較できない。IFRS 企業では
   同じ sectionType に複数 role（例: 損益計算書と包括利益計算書）が存在し得るため、
   role をタグごとに別々に選ぶと異なる木の order 値が混ざり順序が壊れる（Sony 6758
   IFRS で発見・回帰防止済み）。role が取得できないタグ（企業拡張タグ等）はタグ名の
   アルファベット順へフォールバックする。

   **学び2（Opus監査で発見・修正済み）**: 「代表 role」の初版実装は「facts 内で最も出現頻度が
   高い role」を選ぶ方式だったが、これは誤り。ソニー 6758・トヨタ 7203 の IFRS 連結BSでは、
   実際に採用される連結IFRSタグ集合をカバーしない別の role（`rol_BalanceSheet`）の方が
   生fact数（非連結・複数年度分を含む）で勝ってしまい、選ばれたroleの木には採用済みタグが
   1つも含まれず全行の order が nil になって旧アルファベット順へサイレント劣化していた
   （キャッシュ済み実XBRL 165件・489セクションのうち16%で発生。Opus監査でのローカルXBRL
   キャッシュに対する実データ診断で発見）。正しい基準は「頻度」ではなく「実際に採用された
   タグ集合をどれだけカバーするか」で、`primaryRole` をカバレッジ基準に修正して解消した
   （回帰テスト: `StatementClassifierTests.choosesRoleByCoverageOfChosenItemsNotByRawMentionFrequency`）。
   修正後、S100QZT6 は48/48行、S100VWVY は49/49行で order が付与されることをローカル
   XBRLキャッシュで再検証済み。

   実データ検証（トヨタ 7203 J-GAAP・ソニー 6758 IFRS、使い捨て Neon）で BS/PL とも
   presentation linkbase 通りの並び（現預金→流動資産→固定資産、売上高→売上原価→
   営業利益→…→当期純利益等）を確認済み。ソニー IFRS の PL は費用の内訳が収益より
   先に並ぶ等、直感的な「売上高が先頭」という期待と異なる箇所があるが、これは
   presentation linkbase 上の実際の構造であり抽出側の不具合ではない
4. **企業拡張タグの識別フラグ**: v1 では見送る。理由: `XbrlFact`（`Analysis/XBRLTypes.swift`）が
   qualifiedName の namespace prefix を保持しておらず、追加するには `collectNumericFacts` 系の
   XML パーサ本体の拡張が要る（影響範囲が `XBRLUtils.swift` 全体に及ぶ）。実需が具体化してから
   `StatementLineItem` に非破壊で追加できる（Codable のため後方互換）
5. **半期報告書への対応**: v1 では対象外（通期のみ）。`company_half_financials` 同様の需要が
   あるかは未確認のため、まず本体（通期）を出荷してから判断する

## 関連ドキュメント

- `docs/feature-tiers.md` — Statement の境界（free/paid 分離方針）
- `docs/breakdown-normalization-concept.md` — Stage 6（対比: LLM が必要になった理由）
- `docs/blt-server-roadmap.md` — Stage 7/8 の索引ポインタ
- `.agents/rules/project/xbrl-analysis.md` — `XBRLUtils` 共通関数の使用規約
- `.agents/rules/project/versioning.md` — cache_version / min_servable の運用規則
