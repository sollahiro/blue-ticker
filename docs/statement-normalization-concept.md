# 財務諸表完全正規化の構想（statements / statement-notes）

有価証券報告書 XBRL の BS/PL/CF/SS を、絞り込みなしで構造化して返す機能（Statement）の設計メモ。
関連: Summary/Waterfall（`docs/feature-tiers.md`）は絞り込み指標、Breakdown（breakdowns、
`docs/breakdown-normalization-concept.md`）は事業別・地域別売上の意味正規化。Statement は
どちらとも異なり「開示された全項目を、企業間の科目統一を試みず、忠実に構造化する」ことが本体。

## 目的

| 機能 | 提供価値 | 対象範囲 |
|---|---|---|
| Summary / Waterfall | 絞り込んだ主要指標（売上・利益・ROE 等 ~20 項目） | `Extractors.swift` の**固定タグリスト** |
| Breakdown | 事業別・地域別売上の**企業間比較用**正規化スナップショット | セグメント注記・地域注記のみ |
| **Statement**（本構想） | 開示された BS/PL/CF/SS の**全項目**をそのまま構造化 | XBRL 全 fact（標準タグ＋企業拡張タグ） |

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
  どのタグがどの財務諸表（BS/PL/CF/SS）に属するかは、この roleURI から機械的に決まる
- **`filterFactIndexBySections`**（同ファイル 310 行目）で role/section を条件に fact index を
  絞り込む既存関数があり、BS/PL/CF/SS への振り分けにそのまま使える

Duration（PL・CF・SS）/Instant（BS）の判定、連結／非連結コンテキストの判定は
`Analysis/FieldParser.swift`・`Analysis/ContextHelpers.swift` の既存ロジックを流用する
（`.agents/rules/project/xbrl-analysis.md` の「コンテキスト判定は共通化しない」方針通り、
新規に書き直さない）。CF/SS の期首/期末残高行は Instant も受理する（下記）。

**Breakdown（breakdowns）で LLM が必要だった理由との対比**: Breakdown のセグメント注記・地域注記は
「企業ごとに構成が不揃いな自由形式 HTML 表」を人間が読む前提で開示されており、軸判定・変則表の
解釈に意味理解が要る。一方 BS/PL/CF/SS は XBRL 標準タクソノミの presentation linkbase で構造
（どの財務諸表のどこに属するか）が標準化されている。**タグ抽出＋linkbase メタデータの機械的な
組み立てで完結し、LLM によるフォールバックは不要**と判断する。

### 実データ検証（2026-07-29、キャッシュ済み実 XBRL 158社）

対象は日経225限定で実装する（breakdowns と同じ `assets/nikkei225.csv` / `priorityIngestCodes()` を
流用。breakdowns は LLM 費用抑制が理由だったが、statements はまず対象を絞って検証コストを下げる目的）。

ローカルにキャッシュ済みの実 XBRL 158社分に対し `collectAllNumericFacts` を実行し、
role URI の末尾セクション名（`sectionNameFromRole`）の分布を確認したところ、
J-GAAP/IFRS 問わず以下のキーワード判定に収束することを確認した（`Analysis/StatementClassifier.swift`
として実装済み）。

| 会計基準 | BS | PL | CF | SS |
|---|---|---|---|---|
| J-GAAP | `BalanceSheet` / `ConsolidatedBalanceSheet` | `StatementOfIncome` / `ConsolidatedStatementOfIncome` | `StatementOfCashFlows-indirect` / `ConsolidatedStatementOfCashFlows-indirect` | `StatementOfChangesInEquity` / `ConsolidatedStatementOfChangesInEquity` |
| IFRS | `ConsolidatedStatementOfFinancialPositionIFRS` | `ConsolidatedStatementOfProfitOrLossIFRS` | `ConsolidatedStatementOfCashFlowsIFRS` | `ConsolidatedStatementOfChangesInEquityIFRS` |

SS の role キーワードは `StatementOfChangesInEquity` の1語で J-GAAP/IFRS を吸収（2026-08-09、
トヨタ7203 S100VWVY で確認）。SS は資本構成員軸を持つ。合計列に加え、Sankey の当期包括利益分割
向けに次の構成員列だけを `equity_member` 付きで返す（資本金・自己株式など他列の行列展開はしない）:

| `equity_member` | IFRS Member | J-GAAP Member |
|---|---|---|
| （nil = 合計列） | 次元なし | 次元なし |
| `equity_attributable_to_owners_of_parent` | `EquityAttributableToOwnersOfParentIFRSMember` | `ShareholdersEquityMember` |
| `non_controlling_interests` | `NonControllingInterestsIFRSMember` | `NonControllingInterestsMember` |
| `retained_earnings` | `RetainedEarningsIFRSMember` | `RetainedEarningsMember` |
| `other_components_of_equity` | `OtherComponentsOfEquityIFRSMember` | `ValuationAndTranslationAdjustmentsMember` |

検証で分かった注意点（キーワードリストは `Constants/Xbrl.swift` に実装済み）:

1. **`Notes` 接頭辞のロールを先に除外する必要がある** — `NotesConsolidatedBalanceSheet` のような
   注記系ロールにも `"BalanceSheet"` という文字列が含まれるため、単純な部分一致だけだと注記
   （statement-notes 対象）が本体に混入する。`StatementClassifier.classify(role:)` は判定の入口で
   `Notes` 接頭辞を除外する
2. **連結優先・非連結フォールバックが実際に必要** — 158社中ほとんどは `Consolidated*` ロールを
   持つが、9社ほどは `Consolidated` が付かないロールしか持たない（子会社を持たない小規模企業。
   Breakdown（breakdowns）の学びと同型）。ただし連結/非連結の判定自体は role 名ではなく
   **contextRef**（`ContextHelpers.isConsolidatedInstant/Duration`）で行う。非連結側は
   `isNonConsolidatedInstant/Duration` ではなく `isPureNonConsolidatedContext`（完全一致）を使う
   — 前者は `_NonConsolidatedMember` に続けてセグメント軸メンバーが付いた dimensioned context も
   部分一致で拾ってしまい、同一タグにセグメント別の値が複数紐づく事故になるため（監査で指摘・
   `StatementClassifierTests.nonConsolidatedFallbackExcludesSegmentDimensionedContexts` で回帰）

未検証事項: 銀行・保険等の特殊タクソノミを持つ会社が今回の158社サンプルに含まれているかは
未確認（Breakdown（breakdowns）では銀行が別経路を要した理由は「指標タグが別概念」であり構造自体が
崩れたわけではないため、Statement は「そのまま出す」設計上は影響を受けにくいと考えられるが、
実際の日経225銀行株での検証は未実施）。

**US-GAAP**: 連結財務諸表に `ix:nonFraction` が無く Statement（XBRL fact 経路）では正規化できないため、
会計基準検出で明示 `notApplicable(us_gaap_unsupported)` とする（2026-08-09 実装、`statement-v1` のまま）。
個別 BS への silent fallback は廃止。`borrowings_schedule` も同 reason。financials/IBD の
`USGAAPHtml` 経路は現行 summary 用として別。連結 HTML→Statement 行の配線は未着手。

## 公開面設計（free / paid 分離）

`docs/feature-tiers.md` の既存ルール:

> 機能の課金境界はエンドポイント・ツール単位で決める（フィールド単位のマスキングではない）

本体（BS/PL/CF）を無料、注記（notes）を有料にする場合、Breakdown の `axis=business|geography`
のような**同一エンドポイント内のクエリパラメータ分岐では課金境界を満たせない**（両軸とも同じ
ティアだから成立していた設計であり、ティアを分けたい場合の前例にはならない）。

Summary/Waterfall と同型の**別エンドポイント・別ツール**分割を採用する。

| 機能 | REST | MCP | ingest 対象 | 想定ティア |
|---|---|---|---|---|
| Statement（本体） | `GET /v1/companies/{code}/statement` | `get_statement` | statements | 無料想定 |
| Statement Notes（注記、表示名は「Note」） | `GET /v1/companies/{code}/statement/notes` | `get_statement_notes` | statement-notes | 無料（`docs/feature-tiers.md`参照、構造化層は無料方針へ転換） |

両者は別テーブル・別 ingest 対象として設計する（本体は決定論のみで完結するが、注記は
breakdowns 同様 LLM フォールバックが必要になる可能性が高く、staleness・再計算方針が本体と異なる
ため。詳細は「statement-notes（今後）」参照）。

## 抽出の実装（今回追加）

- `Analysis/StatementClassifier.swift`: role → BS/PL/CF/SS 判定（`classify(role:)`）と、
  fact index から指定 section type の当期・連結優先／非連結フォールバック行を抽出する
  `extractLineItems(from:sectionType:)`。表示順は presentation linkbase の実際の並び順
  （`XBRLUtils.loadPresentationOrder` / `XbrlFact.orderByRole`）を使い、取得できないタグは
  タグ名のアルファベット順へフォールバックする（2026-07-30、「実装方針」3 で確定）
- `Services/StatementAnalyzer.swift`: 単一書類（docID）の XBRL をダウンロードし、要求された
  statement type だけを `StatementClassifier` で抽出して `StatementYear` を返す。
  `IndividualAnalyzer`（financials）と異なり複数年度の履歴集約は行わない（1書類＝1年度分のみ）
- `Server/BltServerFacade.swift` の `extractStatement(docID:statementTypes:)`:
  filing-sections の `extractFilingSections(docID:)` と同型の facade メソッド。現時点では
  ingest からの呼び出しはなく、DevCLI からのみ呼ばれる
- `DevCLI/DevStatementCommand.swift`（`ticker-dev statement <code> [docID] --bs --pl --cf --ss`）:
  目視確認用の開発コマンド。`--bs`/`--pl`/`--cf`/`--ss` は**少なくとも1つ必須**（未指定はエラー。
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
  balance_sheet:      [StatementLineItem]
  income_statement:   [StatementLineItem]
  cash_flow:          [StatementLineItem]
  changes_in_equity:  [StatementLineItem]   # SS（合計列 + Parent/NCI/RE/OCE。2026-08-09）

StatementLineItem
  tag, label, value, unit, order, equity_member?
```

`StatementComputeResult`（`.success` / `.notApplicable` / `.failed`）は `FinancialsComputeResult`
と同じ3値パターン（`.agents/rules/project/error-handling.md`）に合わせた。

2026-07-29 に DB モデル（`company_statements`）・ingest（`StatementIngest.swift`）・REST
（`GET /v1/companies/{code}/statement`）・MCP（`get_statement`）配線を実装し、使い捨て Neon
への実 EDINET 取り込み・REST/MCP 読み出しまで検証済み（下記「実装方針」参照）。

## ロードマップ上の位置づけ

- **statements（本体・BS/PL/CF/SS）**: 抽出ロジック（`StatementClassifier`/`StatementAnalyzer`）と
  DevCLI での目視確認は実装済み（PR #153）。DB モデル・ingest・REST・MCP 配線も
  下記「実装方針」に沿って実装済み（2026-07-29、対象は日経225限定でスタート。使い捨て Neon
  への実データ書き込み・読み出しまで検証済み）。SS（持分変動計算書）は 2026-08-09 に追加
  （合計列＋Parent/NCI/RE/OCE、`statement-v1` のまま）。日経225全社への本番ingestはこれから
  （`assets/nikkei225.csv` を持つ本番/ローカル環境で `blt-server ingest --stages statements` を実行）。
- **statement-notes（注記）**: DB モデル・ingest・REST（`GET /v1/companies/{code}/statement/notes`）・
  MCP（`get_statement_notes`）まで実装済み（2026-08-02、note_type 9種、対象は日経225限定）。
  決定論のみ（LLM不要）で完結すると判明したため、当初想定していたLLMフォールバックは未使用。
  詳細は `docs/blt-server-roadmap.md`「statement-notes」行参照。

## 今回（PR #153）のスコープ外（非ゴール）

PR #153（抽出ロジック・DevCLI）時点の切り分け。~~取り消し線~~の項目は下記「実装方針」で実装済み。

- ~~DB モデル・マイグレーション・`StatementIngest.swift`・REST ルート・MCP ツール配線~~ → 実装済み（下記「実装方針」参照）
- ~~複数年度の履歴集約~~ → `StatementIngest` が `filingSectionCandidates` の docID 反復で対応済み（下記「実装方針」2）
- ~~注記（statement-notes）の抽出方式・対象注記の確定・LLM 要否判断~~ → note_type 9種を決定論のみ
  （LLM不要）で実装済み（2026-08-02、`docs/blt-server-roadmap.md`参照）
- 企業拡張タグの正規化ポリシー（そのまま出すか、正規化するか）の確定
- 企業間の科目名統一（Breakdown 的な意味正規化）

## 実装方針（StatementIngest/DB/REST/MCP 着手時に確定、2026-07-29）

PR #153 時点の「未決事項」を次のとおり確定した。DB モデル・`StatementIngest.swift`・REST・MCP は
本方針に沿って実装する。

1. **対象母集団**: **日経225限定**（filing-sections/breakdowns と同じ `assets/nikkei225.csv` /
   `priorityIngestCodes()` を流用）で開始する。statements は LLM を使わないためコスト制約はないが、
   実データ検証が158社（ほぼ日経225相当）に留まり、銀行・保険等の特殊タクソノミでの検証が
   未実施（上記「未検証事項」参照）。母集団拡大（全銘柄化）はこのリスクを解消したうえで
   `docs/blt-server-roadmap.md` の TODO に別項目として積む
2. **複数年度の履歴集約**: `StatementAnalyzer` 自体は単一書類のみのままでよい。`StatementIngest` は
   breakdowns と同じく `filingSectionCandidates`（`listedCodes × 有報(120) × 直近 filingSectionsIngestYears 件`）を
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
5. **半期報告書への対応**: v1 では対象外（通期のみ）。需要があるかは未確認のため、
   まず本体（通期）を出荷してから判断する
6. **BS/CF 行の区分（`section`）**: v1 のうちに実装した（2026-07-30、`order` と同じ理由で
   `statement-v2` を切らず v1 のまま拡張。本番 `company_statements` の日経225全社ingestが
   まだ未実施のため移行コストが実質ゼロ）。`StatementLineItem.section` に BS は
   `assets`/`liabilities`/`net_assets`、CF は `operating`/`investing`/`financing` を付与する
   （配列構造は維持。複数区分にまたがる合計行（例: 資産合計＋負債純資産合計）は該当する祖先を
   持たないため `nil` のまま）。PL の利益段階ラベリング（売上総利益/営業利益/経常利益等）は
   会計基準を跨いだタグ正規化が必要になり「企業間の科目名統一」そのものに当たるためスコープ外に
   確定した（2026-07-30、ユーザー合意。financials の `computeFinancials` の領域）。

   判定は `order` と同じ presentation linkbase を使うが、表示順（同一 role 内の深さ優先番号）とは
   別に、タグの presentation 祖先を辿って最初にキーワード一致した区分で確定する
   （`XBRLUtils.loadPresentationParents` / `StatementClassifier.lineSection`）。祖先を辿るのは、
   BS/CF の区分が個々のタグ名ではなく presentation linkbase 上の親子関係でしか判定できないため
   （例: `CashAndDeposits` 自体は区分を表す語を含まないが、祖先 `CurrentAssetsAbstract` →
   `AssetsAbstract` を辿ると「資産」と分かる）。

   **学び1**: BS の判定順は 純資産/資本（`NetAssets`/`Equity`）→ 負債（`Liabilit`）→ 資産（`Asset`）
   でなければならない。標準タクソノミの `NetAssetsAbstract` は文字列 "Assets" を部分文字列として
   含むため、資産キーワードを先に判定すると純資産科目（`ShareholdersEquityAbstract` 等の祖先が
   `NetAssetsAbstract` のケース）が資産へ誤分類される。

   **学び2**: presentation linkbase には、同一タグが役割内で2回 `<loc>` される実データパターンが
   存在する（実データ検証: ソニー6758 IFRS の `ChangesInWorkingCapitalOpeCFIFRSAbstract`）。
   1回は明細の見出しとして親を持たない root、もう1回は上位ツリーの子として参照される
   （親を持つ）。タグ単位で複数の親候補を集合として持たせ、BFS で経路を辿ることで、root 側の
   出現からでも正しい区分へたどり着けるようにした。

   実データ検証（トヨタ 7203 J-GAAP単体BS＋IFRS連結BS/CF、ソニー 6758 IFRS連結BS/CF、
   出光興産 5019 J-GAAP連結BS/CF、いずれもキャッシュ済み実XBRL）で DevCLI から目視確認済み。
   グランドトータル行（`LiabilitiesAndEquityIFRS`/`LiabilitiesAndNetAssets` 等）のみ `section=nil`、
   それ以外は全行正しく分類されることを確認済み。Cursor CLI（Grok 4.5）監査済み（問題なし）。

   **学び3（2026-07-30 実データ目視確認で発見・修正済み）**: 負債合計・資産合計等の「タグ自身が
   単一区分を表す合計行」は、直接の親が負債・純資産の両方を束ねる見出し（例:
   `LiabilitiesAndEquityIFRSAbstract`）である IFRS 個別タクソノミが存在する（実データ検証:
   デンソー6902）。祖先を優先順位（NetAssets/Equity→Liabilit→Asset）だけで確定させると
   `LiabilitiesIFRS` が誤って純資産へ分類される。祖先が複数区分のキーワードに同時一致する場合は
   曖昧とみなしてさらに上の祖先を辿り、それでも確定しない場合に限りタグ自身の名前（単一区分に
   曖昧さなく一致する場合のみ）へフォールバックする形に修正した
   （`StatementClassifier.classifyIfUnambiguous`）。

7. **ラベル解決（標準タクソノミ補完・`preferredLabel` 対応、2026-07-30）**: 提出書類自身の
   ラベルリンクベースには拡張タグの分しか同梱されない（標準タクソノミ側は外部参照のみでファイル
   自体は含まれない）。`assets/taxonomy/{GAAP,IFRS}/*.zip`（ユーザーが EDINET から取得し配置。
   git 管理外・`.gitignore` 参照）の最新版（現行＋廃止済み要素）から補完する
   （`XBRLUtils.loadStandardTaxonomyLabels`）。実データ検証（トヨタ・デンソー・任天堂、BS/PL/CF
   計316行）でラベル解決率 21%→100%。`assets/taxonomy` が無い環境（CI・本番等）は従来どおり
   拡張タグ以外が未解決のまま（クラッシュしない）。
   また presentationArc の `preferredLabel`（合計行・期首/期末残高等でどのラベルロールを使うべきかの
   指示）に応じてラベルを差し替える（`XBRLUtils.loadLabelRoleVariants` /
   `StatementClassifier.resolvedLabel`）。実データ検証: 任天堂7974 の `ValuationAndTranslationAdjustments`
   は通常ラベル「評価・換算差額等」ではなく合計ラベル「評価・換算差額等合計」を使うべきケース。
   同一タグが同一 role 内に2回出現するケース（`CashAndCashEquivalentsIFRS` の期首/期末残高）は
   fact 自身の context（前期末=当期首 instant か当期末 instant か）から
   periodStartLabel/periodEndLabel を直接選び直して区別する。

   **Opus 監査で発見・修正（2026-07-31）**: 上記の期首/期末残高判定が当初 CF に限定されておらず、
   標準タクソノミが periodEndLabel を定義している BS の合計行タグ（`EquityIFRS`/`NetAssets` 等）
   まで対象になっていたため、`preferredLabel=totalLabel`（「資本合計」等）が無視され常に
   「期末残高」表示になっていた（キャッシュ済み実XBRL 140件中136件で発生）。CF 限定に修正し、
   さらにロール選択も `Dictionary.first(where:)`（走査順が非決定的）から標準 XBRL ロール
   （`http://www.xbrl.org/2003/role/…`）優先の決定的選択に直した（EDINET 独自の中間報告書用
   ロールと標準ロールが両方存在する場合、以前は実行のたびに異なる文言が選ばれ得た）。

   `loadLabelsByTag`（`Analysis/XBRLUtils.swift`）は statements 専用ではなく filing-sections/breakdowns
   （`BreakdownExtractor` 経由）とも共有する共通関数のため、この標準タクソノミ補完は
   `company_filing_sections`/`company_breakdowns` の格納ラベルにも波及する。`versioning.md` の
   原則（XBRL fact のパースロジック変更時は `xbrlFactsCacheVersion` バンプ）には該当するが、
   本番には `assets/taxonomy` が未配置のため現状は無害と判断し、**このバンプは見送る**（2026-07-31
   ユーザー判断）。`assets/taxonomy` を本番に配置する場合は改めてバンプ要否を検討すること。

8. **ツリー構造（`parent_tag`/`depth`）は不採用（2026-07-30 検討・撤回）**: presentation
   linkbase 上の直接の親タグ・深さを一度実装したが、実データ（デンソー6902）で確認したところ
   「表示上どこにネストするか」の情報でしかなく、v1 では本来解決したかった「合計行の二重計上を
   避ける」問題には効かないと判断し撤回した。その問題は presentation ではなく**計算リンクベース**
   でのみ決定的に解けると判断し、下記10で実装した。

9. **CF の Instant/Duration 混在**: CF は大半が Duration（フロー行）だが、現金及び現金同等物の
   期首/期末残高調整行は Instant 型 fact のまま CF の presentation role に現れる（実データ検証:
   トヨタ7203 の `CashAndCashEquivalentsIFRS` が `periodStartLabel`/`periodEndLabel` として
   CF role 内に2箇所出現）。当初は CF を Duration のみで判定していたため、この Instant fact が
   両判定に失敗し黙って欠落していた（2026-07-30 発見・修正済み。期首残高は当期首=前期末の
   instant context のため、CF に限り前期 Instant も受理する）。

10. **合計行の構成要素（`is_total`/`components`、計算リンクベース由来、2026-07-30 実装）**:
    presentation の親子関係は表示上のネストでしかなく二重計上の防止を保証しないため、
    `_cal.xml`（`summation-item` arc・`weight`）から「この行が他の行の合計かどうか・何を
    足したものか」を決定的に取得する（`XBRLUtils.loadCalculationComponents` /
    `StatementClassifier`）。presentation と同様、同じ sectionType に複数 role
    （IFRS連結用・J-GAAP個別用等）が対応することがあるため role ごとに分けて持ち、
    presentation のカバレッジ基準で選んだのと同じ `primaryRole`（同一 role URI を計算
    リンクベース側でも共有）で1つに絞る。`weight` は加算=+1・控除=−1（実データ上 ±1 のみ確認。
    例: `GrossProfitIFRS = +1*RevenueIFRS + (-1)*CostOfSalesIFRS`）。
    実データ検証（トヨタ・デンソー・任天堂）: BS/PL/CF の合計行のほぼ全てで構成要素が完結し、
    多段階の積み上げ（例: 任天堂7974 `資産合計 = 流動資産合計 + 固定資産合計`、各小計もさらに
    明細に展開）も正しく連鎖することを確認。複数区分にまたがるグランドトータル行（`section=nil`）
    も `is_total`/`components` は正しく取得できる（presentation の区分判定と計算リンクベースの
    構成要素判定は独立した情報源のため）。

## 関連ドキュメント

- `docs/feature-tiers.md` — Statement の境界（free/paid 分離方針）
- `docs/breakdown-normalization-concept.md` — breakdowns（対比: LLM が必要になった理由）
- `docs/blt-server-roadmap.md` — statements/statement-notes の索引ポインタ
- `.agents/rules/project/xbrl-analysis.md` — `XBRLUtils` 共通関数の使用規約
- `.agents/rules/project/versioning.md` — cache_version / min_servable の運用規則
