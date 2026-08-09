# XBRL解析 技術リファレンス

BLUE TICKERにおけるEDINET XBRL解析の設計・実装方針をまとめます。

---

## 1. EDINETのXBRL文書構造

### 1.1 iXBRL パッケージのファイル構成

EDINETが配布するXBRLパッケージは `PublicDoc/` 以下に次の形式で格納されています。

```
PublicDoc/
├── <docid>.xbrl                  # XBRLインスタンス文書（XML形式）
├── <docid>.xsd                   # スキーマ
├── <docid>_lab.xml               # ラベルリンクベース（日本語名称）
├── <docid>_pre.xml               # プレゼンテーションリンクベース
├── <docid>_cal.xml               # 計算リンクベース
├── <docid>_def.xml               # 定義リンクベース
├── 0101010_honbun_*_ixbrl.htm    # 主要な経営指標等（決算短信サマリー）
├── 0102010_honbun_*_ixbrl.htm    # 事業の状況
├── 0103010_honbun_*_ixbrl.htm    # 設備の状況
├── 0104010_honbun_*_ixbrl.htm    # 提出会社の状況
├── 0105010_honbun_*_ixbrl.htm    # 連結財務諸表（連結BS/PL/CF）
├── 0105020_honbun_*_ixbrl.htm    # 個別財務諸表
├── 0106010_honbun_*_ixbrl.htm    # 注記（継続企業の前提等）
└── 0107010_honbun_*_ixbrl.htm    # 附属明細表
```

### 1.2 `.xbrl` インスタンス文書の役割

`.xbrl` ファイルは、各 `.htm` ファイル内の `ix:nonFraction` タグで定義されたすべての数値を XML に集約したインスタンス文書です。`XBRLUtils.findXbrlFiles` および `XBRLUtils.collectNumericElements` はこのファイルを対象にします。

**`findXbrlFiles` が返すファイル種別**

| 種別 | 対象 | 除外 |
|---|---|---|
| `.xml` | マニフェスト等のXML | `_lab`, `_pre`, `_cal`, `_def` 付きファイル |
| `.xbrl` | XBRLインスタンス文書 | なし |
| `.htm` / `.html` | **対象外**（HTMLは別途SwiftSoupでパース） | — |

---

## 2. 会計基準の判定

XBRL タグの有無から会計基準を推定します。`FieldParser.swift` の `detectAccountingStandard(_:)` が判定し、各エクストラクターに渡されます。

### 判定ロジック

収集済みタグ名に対する部分文字列マッチで判定します（固定のマーカータグリストは持ちません）。

```
US-GAAP  ← タグ名に "USGAAP" を含むタグが存在 かつ "IFRS" を含むタグが不在
IFRS     ← タグ名に "IFRS" を含むタグが存在
J-GAAP   ← 上記いずれにも該当しない
```

> **注意**: IFRSへ移行済みの企業でも、過去比較データとして `*USGAAP*` タグが残存することがあります。「USGAAPタグが存在してもIFRSタグがあれば IFRS と判定」という優先順位でこれを吸収しています。

---

## 3. コンテキスト体系

XBRL の `contextRef` 属性は財務諸表の種別・期間・連結区分を表します。

### 3.1 コンテキストの分類

| 次元 | 値の例 | 説明 |
|---|---|---|
| **期間種別** | `Duration` / `Instant` | フロー（損益・CF）/ ストック（BS） |
| **連結区分** | （なし）/ `_NonConsolidated` | 連結 / 個別 |
| **当期・前期** | `CurrentYear` / `Prior1Year`, `PriorYear` | 当期・前期 |
| **期の形式** | `FYDuration` / `InterimDuration` / `YTDDuration` | 通期・中間期・累計 |

### 3.2 コンテキストパターン（`Constants/Xbrl.swift`）

**Duration コンテキスト（損益計算書・CF計算書）**

| 定数名 | パターン | 意味 |
|---|---|---|
| `Xbrl.durationContextPatterns` | `CurrentYearDuration` | 連結 当期（年次通期） |
| | `FilingDateDuration` | 連結 当期（提出日基準） |
| | `InterimDuration` | 連結 当期（新形式 中間期） |
| | `CurrentYTDDuration` | 連結 当期（旧形式 中間・四半期累計） |
| `Xbrl.priorDurationContextPatterns` | `Prior1YearDuration` | 連結 前期（年次） |
| | `PriorYearDuration` | 連結 前期（年次 別名） |
| | `Prior1InterimDuration` | 連結 前期（中間期） |
| | `Prior1YTDDuration` | 連結 前期（累計） |

**Instant コンテキスト（貸借対照表）**

| 定数名 | パターン | 意味 |
|---|---|---|
| `Xbrl.instantContextPatterns` | `CurrentYearInstant` | 連結 当期末 |
| | `CurrentQuarterInstant` | 連結 当期末（四半期） |
| | `InterimInstant` | 連結 当期末（中間期） |
| | `FilingDateInstant` | 連結 当期末（提出日基準） |
| `Xbrl.priorInstantContextPatterns` | `Prior1YearInstant` | 連結 前期末 |
| | `PriorYearInstant` | 連結 前期末（別名） |
| | `Prior1QuarterInstant` | 連結 前期末（四半期） |
| | `Prior1InterimInstant` | 連結 前期末（中間期） |

`_NonConsolidated` が含まれるコンテキストは個別財務諸表の値です。

---

## 4. 解析モジュール一覧

### 4.1 FieldSet アーキテクチャ

各エクストラクターは `FieldSet`（`[String: FieldValue]`、タグ名 → 当期/前期値）を受け取ります（`Analysis/FieldParser.swift`）。`FieldParser` が XBRL から関連タグを収集・正規化し（Duration / Instant / 非連結の各 FieldSet）、`detectAccountingStandard(_:)` が会計基準を判定した上でエクストラクターに渡します。これにより各エクストラクターはコンテキスト解決を意識せず、タグ名の優先順リストを渡すだけで値を取得できます。

**FieldSet の種別（`FieldParser.swift` のビルダー）**

| ビルダー | 期間種別 | 主な用途 |
|---|---|---|
| Duration FieldSet | Duration | 損益計算書・CF計算書・株主資本等変動計算書 |
| Instant FieldSet | Instant | 貸借対照表・従業員数 |
| 非連結 Duration / Instant FieldSet | — | 連結値がない場合の個別財務諸表フォールバック |

### 4.2 エクストラクター一覧（`Analysis/Extractors.swift`）

| エクストラクター | 抽出内容 |
|---|---|
| `IncomeStatementExtractor` | 売上高・営業利益・純利益・会計基準 |
| `GrossProfitExtractor` | 売上総利益（直接法→計算法のフォールバック、銀行業務粗利益含む） |
| `OperatingProfitExtractor` | 営業利益（直接法→GP-SGA計算法のフォールバック） |
| `InterestExpenseExtractor` | 支払利息（IFRS 注記テキスト抽出含む） |
| `TaxExpenseExtractor` | 税引前利益・法人税等・実効税率 |
| `RDExtractor` | 研究開発費 |
| `NetRevenueExtractor` | IFRS金融会社向け純収益・事業利益 |
| `CashFlowExtractor` | 営業CF・投資CF |
| `CapexExtractor` | 設備投資額（設備投資等概要→CF順） |
| `ShareBuybackExtractor` | 自己株式取得額（株主資本変動計算書→CF順） |
| `BalanceSheetExtractor` | 総資産・流動/固定資産・流動/固定負債・純資産 |
| `IBDExtractor` | 有利子負債合計（直接法→積み上げ法のフォールバック、銀行固有コンポーネント含む） |
| `TangibleFixedAssetsExtractor`（PPE） | 有形固定資産合計・内訳 |
| `EmployeesExtractor` | 従業員数（連結→個別フォールバック） |
| `BreakdownExtractor`（`BreakdownExtractor.swift`） | セグメント情報・地域別情報（TextBlock HTML表 → dimension付きfact）。企業間比較向け正規化構想は `docs/breakdown-normalization-concept.md` |

### 4.3 売上総利益（`GrossProfitExtractor`）

```
US-GAAP → USGAAPHtml.extractGrossProfit の HTML パース（§5 参照）

J-GAAP / IFRS:
  1. 直接法: Xbrl.grossProfitDirectTags を検索
     - GrossProfitIFRS（IFRS連結）
     - GrossProfit（J-GAAP連結）
     - GrossProfitOnCompletedConstructionContractsCNS（建設業）
     - OperatingGrossProfit（倉庫・運輸等 J-GAAP 営業総利益）
  2. 計算法: 売上高タグ − 売上原価タグ（直接法で取得できなかった場合）
     - Xbrl.grossProfitSalesTags / Xbrl.grossProfitCostsTags 参照
  3. 銀行業: Xbrl.businessGrossProfitComponents（収益/費用の符号付き合算）
  4. IFRS PL TextBlock フォールバック（連結PLがTextBlockのみの場合）
  5. 連結値がなければ個別値にフォールバック
```

### 4.4 有利子負債（`IBDExtractor`）

```
US-GAAP → USGAAP_HTML_IBDCurrent / IBDNonCurrent 仮想タグを取得（§5 参照）
銀行業  → Xbrl.bankIBDComponents（預金・借用金等の銀行固有コンポーネント）

J-GAAP / IFRS:
  1. 直接法: Xbrl.ibdDirectTags（InterestBearingDebt / InterestBearingLiabilities）
  2. 積み上げ法: Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents（7〜9コンポーネント）
     - J-GAAP/IFRS 両タグを優先順で試行（ShortTermLoansPayable → BorrowingsCLIFRS 等）
     - リース負債（LeaseObligationsCL / NCL、IFRS は IFRSLease.swift の TextBlock 抽出含む）
  3. IFRS集約タグ: 粒度別タグ不在時は Xbrl.ibdIFRSCLTags / Xbrl.ibdIFRSNCLTags で代替
     （BondsAndBorrowingsCLIFRS / BondsBorrowingsAndLeaseLiabilitiesCLIFRS 等）
  4. 連結値がなければ個別値にフォールバック
```

### 4.5 営業利益（`OperatingProfitExtractor`）

```
1. 直接法: Xbrl.operatingProfitDirectTags
   - OperatingProfitLossIFRS（IFRS）
   - OperatingIncomeLoss / OperatingIncome（J-GAAP）
   - USGAAP_HTML_OperatingIncome（US-GAAP仮想タグ、§5 参照）
2. 計算法: GrossProfit − SGA（IFRS で OperatingProfitLossIFRS が存在しない日立等向け）
   - SGA は SellingGeneralAndAdministrativeExpensesIFRS / JGAAP を直接取得
   - または SellingExpensesIFRS + GeneralAndAdministrativeExpensesIFRS を合算
3. 経常利益フォールバック: Xbrl.ordinaryIncomeTags（J-GAAP 金融機関向け。IFRS企業では抑止）
```

---

## 5. US-GAAP固有の制約とHTMLパース

### 5.1 US-GAAP 企業の XBRL 上の制約

US-GAAP 採用企業（例: 富士フイルム 4901、キヤノン 7751）では、**連結財務諸表（0105010）に `ix:nonFraction` タグが存在しません**。これは EDINET の iXBRL 対応が US-GAAP の連結勘定科目に未対応であるためです。

```
0101010（決算短信サマリー）→ *USGAAPSummaryOfBusinessResults タグあり（売上高等）
0105010（連結財務諸表）    → ix:nonFraction タグなし（純 HTML テーブル）
0105020（個別財務諸表）    → XBRL タグあり（注記セクション等）
```

このため US-GAAP 企業の BS / PL 数値は HTML をパースする必要があります。

### 5.2 仮想タグアーキテクチャ（`USGAAP_HTML_*`）

US-GAAP HTML パースの結果は **仮想タグ** として `FieldSet` に注入されます。仮想タグを受け取る各エクストラクターは、仮想タグを通常の XBRL タグと同列に扱うだけでよく、US-GAAP 固有の処理を意識しません。

```
HTML パース（Analysis/USGAAPHtmlFields.swift）
  → USGAAP_HTML_CurrentAssets / CurrentLiabilities / ...
  → USGAAP_HTML_PPENet / BuildingsGross / MachineryGross / ...
  → USGAAP_HTML_IBDCurrent / IBDNonCurrent
  → USGAAP_HTML_OperatingIncome / SGA / PreTaxIncome / ...

FieldSet に merge
  ↓
BalanceSheetExtractor / IBDExtractor 等が
通常の J-GAAP / IFRS タグと同じ優先順リストで解決
```

US-GAAP と判定された場合に `USGAAPHtml.parseBSFields` / `USGAAPHtml.parsePLFields` を呼び出して `FieldSet` に追記します。

### 5.3 `USGAAPHtmlFields.swift` のカバー範囲

| 関数 | 対象ファイル | 生成する仮想タグ（主要） |
|---|---|---|
| `USGAAPHtml.parseBSFields` | `0105010_*_ixbrl.htm` | CurrentAssets / NonCurrentLiabilities / PPENet / IBDCurrent / IBDNonCurrent / NetAssets 等 |
| `USGAAPHtml.parsePLFields` | `0105010_*_ixbrl.htm` | OperatingIncome / SGA / PreTaxIncome / IncomeTax 等 |

HTMLテーブルのラベル文字列 → 仮想タグ名のマッピングは `USGAAPHtmlFields.swift` の辞書（`bsLabelMap` / `plLabelMap`）で一元管理されています。ヘッダー列検出（前期/当期の列インデックス特定）は `HtmlFinancialTable` に統合されています。

### 5.4 売上総利益のHTMLパース（`USGAAPHtml.extractGrossProfit`）

**対象ファイル**: `0105010_*_ixbrl.htm`（連結損益計算書）

**テーブル構造**（富士フイルム方式）

```
ヘッダー行1: | （区分）| （注記）| 前連結会計年度(colspan=2) | 当連結会計年度(colspan=2) |
ヘッダー行2: | 区分     | 注記番号 | 金額(百万円)(colspan=2)   | 金額(百万円)(colspan=2)   |
データ行:    | Ⅰ 売上高  | 注２，４ |         | 2,960,916 |         | 3,195,828 |
             | Ⅱ 売上原価|         |         | 1,774,656 |         | 1,895,749 |
             | 売上総利益 |         |         | 1,186,260 |         | 1,300,079 |
```

- データ行は6列: `[ラベル, 注記, 前期サブ, 前期合計, 当期サブ, 当期合計]`
- ヘッダーの `colspan` を展開して列インデックスを特定し、最近傍マッチで値を取り出す

```swift
// colspan展開で物理列インデックスを算出（ヘッダーセルのspan-1が合計列）
// HtmlFinancialTable.detectColumnIndexes(rows:) が実装
var colOffset = 0
for cell in headerCells {
    let span = XBRLUtils.parseHtmlIntAttribute(cell, "colspan")
    let lastCol = colOffset + span - 1   // colspan=2 なら offset+1 が合計列
    if text.contains("当連結") { currentColIdx = lastCol }
    else if text.contains("前連結") { priorColIdx = lastCol }
    colOffset += span
}

// 最近傍マッチ（単純な「<=2」ではなく最小距離を選択）
// HtmlFinancialTable.nearestValue(to:in:) が実装。距離 2 以内のみ採用
```

### 5.5 支払利息のHTMLパース（`USGAAPHtml.extractInterestExpense`）

US-GAAP 企業では `ix:nonFraction` が存在しないため、連結損益計算書 HTML から支払利息を取得します。`parsePLFields` が生成する `USGAAP_HTML_` 系仮想タグには支払利息が含まれないため、`USGAAPHtml.extractInterestExpense` が個別に HTMLパースを行います（注記セクションを検索）。

---

## 6. スモークテスト

### 6.1 構成

スモークテストは Swift Testing の一部として実行されます（`swift test`）。期待値は `smoke/` ディレクトリで管理します。

```
smoke/
  smoke_expected/         # 年次期待値 JSON（{code}_{fy_end}.json）
  breakdown_extraction_expected.json   # セグメント・地域別抽出の期待値（書類ID別）
  smoke-field-values.md   # フィールド一覧とスモークテストの仕様説明
```

| テスト | 実装 | 照合対象 |
|---|---|---|
| 年次スモーク | `SwiftTests/BlueTickerTests/Spec/Oracle/SmokeTests.swift` `testSmokeAll` | `smoke_expected/` |
| セグメントパリティ | `BreakdownExtractorTests.swift` `SegmentParityTests` | `breakdown_extraction_expected.json` |
| 内訳(breakdown)実データ回帰 | `SwiftTests/BlueTickerTests/Spec/Oracle/RealXbrlBreakdownTests.swift`（4 `@Suite`: Extraction / EmployeesRD / Resolver / LiveLLM） | `smoke/` 配下は使わない。対象企業は各 `@Test` 関数にハードコード（一覧は同ファイル参照） |
| 注記(statement-notes)実データ回帰 | `SwiftTests/BlueTickerTests/Spec/Oracle/RealXbrlStatementNotesTests.swift`（`golden*` 関数群） | `smoke/` 配下は使わない。対象企業は各 `@Test` 関数にハードコード |
| 注記(borrowings_schedule)外出しオラクル試作 | `SwiftTests/BlueTickerTests/Spec/Oracle/StatementNotesOracleFormatTests.swift` | `smoke/statement_notes_borrowings_schedule_expected.json`（`docs/test-spec-assets.md` の C。期待値をSwiftコード外へ出した試作、3docIDのみ） |
| IBD⇔借入金等明細表 横断INVARIANT | `SwiftTests/BlueTickerTests/Spec/Invariant/CrossModuleInvariantTests.swift` | ハードコードなし。`BorrowingsSchedule.extract` と `resolveBorrowingsSchedule` の合計一致を検証（`docs/test-spec-assets.md` の D） |

`SPEC_*` ラベルに基づくサブフォルダ移動（`docs/test-spec-assets.md` の E）を実施済み。`SwiftTests/{BlueTickerTests,BltServerCoreTests}/Spec/{Oracle,Invariant,Contract,Policy}/` に該当ファイルを移動し、ラベルが混在するファイル（`StatementContractTests.swift` 等）や UNCLASSIFIED が優勢なファイルは元の場所に残している（一覧は `docs/test-spec-inventory.md`）。SwiftPM のテストターゲットはサブフォルダを再帰的に含むため `Package.swift` の変更は不要。

**golden回帰とsmokeの役割の違い**: 2つは同じ「実データ回帰」でも軸が異なる。

- **smoke（年次スモーク）**: 会計基準（J-GAAP/IFRS/US-GAAP）・決算期の移行境界・連結有無など、抽出ロジックが分岐する「次元」を意図して選んだ固定企業セット（§6.2）で、既存ロジック全体の最低品質を継続的に守る**床**。ただし現状の対象は基本財務諸表抽出器（BS/PL/CF/GP/IBD）のみで、**note_type(statement-notes)/breakdownの決定論ロジックはこの床に含まれていない**
- **golden回帰**（年次スモーク以外の3種）: 個別ロジックの実装・改善時に見つけたエッジケースを持つ企業をその都度追加する**深さ**方向の蓄積型で、対象企業の選定基準は「そのロジック分岐を踏む」ことのみ（次元の網羅性は保証しない）

原則としては note_type/breakdown の決定論ロジックもこの床でカバーされるべきだが、現状は未整備というギャップがある。golden側でエッジケースは踏んでいても、smokeが意図的にカバーする次元（銀行・US-GAAP・小規模企業など）での確認がまだ済んでいない場合がある。ロジックが安定してきた段階で、smoke企業セットに対しても回帰対象へ加え、床をnote_type/breakdownまで広げる。

golden/smoke をどう言語非依存の仕様資産として扱うかの長期方針は [test-spec-assets.md](test-spec-assets.md) を参照。

XBRL キャッシュ（`tmp_cache/edinet/`、git 管理外のローカル専用）は `SmokeCacheSupport`（`SwiftTests/BlueTickerTests/SmokeCacheSupport.swift`）が自動管理します。`BLT_EDINET_API_KEY` 環境変数（`blt-server` と共通）が設定されていれば、各テストが対象 docID の不足分を EDINET から自動ダウンロードしてから照合します。未設定でキャッシュも無い docID は個別に SKIP され、テスト全体は失敗しません（Keychain・`ticker config` は不使用）。期待値 JSON は旧 Python 実装の出力をゴールデンとして凍結したもので、更新するにはテストの差分出力を確認し、正しければ上書きします。

`RealXbrlBreakdownTests.swift` はキャッシュ先が `~/.config/blue-ticker/analysis_cache/` と異なる（`smoke/smoke_expected/` の期待値 JSON を経由しない）ため、上記スモーク一式とは別系統として扱ってください。

CI では `swift-macos` ジョブの `Test` ステップに repo secret `BLT_EDINET_API_KEY` を渡しており、実データでの照合が毎回走ります（`.github/workflows/ci.yml`）。

### 6.2 対象企業

| コード | 企業 | 区分 | 確認内容 |
|---|---|---|---|
| `4901` | 富士フイルム | US-GAAP | US-GAAP制約の確認。連結財務諸表に `ix:nonFraction` がなく、BS/PL/GP/IE を HTML パースで補う経路を検証する |
| `7751` | キヤノン | US-GAAP→IFRS移行境界 | 期末 `2026-12-31` 以前は US-GAAP、以降は IFRS を期待する |
| `8306` | 三菱UFJ | J-GAAP金融 | 銀行系。PL/BS抽出と会計基準判定を通しつつ、GP・有利子負債の未検出を許容する |
| `8316` | 三井住友 | J-GAAP金融 | 銀行系。GP・IBD 未検出を許容する |
| `6103` | オークマ | J-GAAP事業 | 標準的なJ-GAAP事業会社。PL/BS/GP/IBD が通ることを見る |
| `6326` | クボタ | IFRS | IFRSタグ体系でPL/BS/GP/IBD抽出が通ることを見る |
| `2802` | 味の素 | IFRS | `GrossProfitIFRS` の直接取得と、IFRS IBD で粒度別タグが一部不足するケースを検証する |
| `7269` | スズキ | J-GAAP→IFRS移行境界 | 期末 `2024-03-31` 以前は J-GAAP、以降は IFRS を期待する |
| `7422` | 東邦レマック | J-GAAP非連結 | 連結財務諸表なし。`has_nonconsolidated_contexts` が False になり、個別財務諸表フォールバックを検証する |
| `3490` | アズ企画設計 | 連結作成開始境界 | 期末 `2024-02-29` 以降から連結作成。`has_nonconsolidated_contexts` が境界前後で変わることを見る |

スモークで必ず確認する抽出器は損益計算書・貸借対照表・売上総利益・有利子負債です。金融会社だけ GP・IBD の未検出を許容します。

---

## 7. EDINETタクソノミ（`assets/taxonomy/`）

`assets/taxonomy/` に格納されている EDINETタクソノミを使うと、標準タグの日本語ラベルや定義を一次資料として確認できます。新しい抽出フィールドの追加やタグ候補の調査時に参照してください。

### 7.1 格納内容と構造

```
assets/taxonomy/
├── GAAP/           # 日本基準（JPPFS タクソノミ）
│   ├── 000_00001_cai*.zip         # 旧形式（〜2012年）
│   └── JPPFS_YYYYMMDD.zip         # 現行形式（2015年〜）
└── IFRS/           # IFRS（JPIGP タクソノミ）
    └── JPIGP_YYYYMMDD.zip
```

ZIP の日付は「このタクソノミが有効になった日」です。企業が提出する `.xbrl` ファイルの `contextRef` に含まれる年度ではなく、EDINETが改訂・公開したタクソノミのバージョンを表します。各年度の有価証券報告書はその提出時点で最新のタクソノミに準拠しています。

**タグのバージョン依存性について**: EDINET タクソノミはバージョン間で後方互換性が維持されており、`CashAndDeposits` や `GrossProfit` などのコアタグは最新版に収録されています。タグ調査には最新バージョン（ファイル名の日付が最も新しいもの）のみ確認すれば十分です。

### 7.2 ZIP 内のファイル構成

```
JPPFS_20251101.zip
├── samples/2025-11-01/
│   └── entryPoint_jppfs_*.xsd       # 業種別エントリポイント（参照用）
└── taxonomy/
    ├── common/2013-08-31/           # 共通スキーマ
    ├── jpdei/2013-08-31/            # 書類提出者情報タクソノミ
    │   └── label/
    │       ├── jpdei_*_lab.xml      # 日本語ラベル
    │       └── jpdei_*_lab-en.xml   # 英語ラベル
    └── jppfs/2025-11-01/
        ├── jppfs_cor_2025-11-01.xsd # コア要素定義（全タグの型・属性を記述）
        ├── jppfs_rt_2025-11-01.xsd  # ロールタイプ定義
        ├── deprecated/              # 廃止タグのラベル（互換性参照用）
        └── label/
            ├── jppfs_2025-11-01_lab.xml     # 日本語ラベル（★主要参照ファイル）
            ├── jppfs_2025-11-01_lab-en.xml  # 英語ラベル
            └── jppfs_2025-11-01_gla.xml     # 汎用ラベル（Abstract/タイトル等）
```

IFRS ZIP（`JPIGP_20251101.zip`）も同構造で、`jppfs` が `jpigp` に置き換わります。

### 7.3 ラベルリンクベース（`_lab.xml`）の読み方

ラベルとタグ名の対応は 3 種類の要素で構成されます。

```xml
<!-- ① loc: タグ名（概念）への参照 -->
<link:loc
  xlink:label="CashAndDeposits"
  xlink:href="../jppfs_cor_2025-11-01.xsd#jppfs_cor_CashAndDeposits"/>

<!-- ② label: ラベルテキスト本体 -->
<link:label
  xlink:label="label_CashAndDeposits"
  xlink:role="http://www.xbrl.org/2003/role/label"
  xml:lang="ja">現金及び預金</link:label>

<!-- ③ labelArc: loc と label を結ぶ弧 -->
<link:labelArc
  xlink:arcrole="http://www.xbrl.org/2003/arcrole/concept-label"
  xlink:from="CashAndDeposits"
  xlink:to="label_CashAndDeposits"/>
```

| 属性 | 役割 |
|---|---|
| `loc/@xlink:label` | この linkbase 内でタグを識別するローカル ID（タグ名と一致） |
| `loc/@xlink:href` | `{ファイル名}#{namespace_prefix}_{タグ名}` 形式で実体を指す |
| `label/@xlink:role` | `role/label`（標準）/ `role/verboseLabel`（詳細名）/ `role/negativeLabel` 等 |
| `label/@xml:lang` | `ja`（日本語）または `en`（英語） |
| `labelArc/@xlink:from` | `loc/@xlink:label` と一致 → タグを特定 |
| `labelArc/@xlink:to` | `label/@xlink:label` と一致 → ラベルテキストを取得 |

`role/label` が「通常の表示名」、`role/verboseLabel` が「タイトル項目付きの詳細名」です。同一タグに複数のラベルが定義される場合は `role/label` を優先します（`LabelLinkbaseParser` の実装と同じ）。

### 7.4 名前空間プレフィックスとタグ名の関係

実際の `.xbrl` インスタンス文書内では名前空間プレフィックスが使われます。

| プレフィックス | 名前空間 URI の特徴 | 対応タクソノミ |
|---|---|---|
| `jppfs_cor:` | `jppfs` を含む URI | JPPFS（日本基準）コアタクソノミ |
| `jpigp_cor:` | `jpigp` を含む URI | JPIGP（IFRS）コアタクソノミ |
| `jpcrp_cor:` | `jpcrp` を含む URI | 共通報告概念（業種横断タグ） |
| `E12345:` | E番号（提出者コード）を含む URI | 企業独自拡張タグ |

タクソノミの `loc/@xlink:href` に含まれる `jppfs_cor_CashAndDeposits` の `jppfs_cor_` 部分がこのプレフィックスに対応します。`LabelLinkbaseParser.conceptLocalName(from:)` は `#` 以降の文字列から最初の `_` までを除去してローカル名（`CashAndDeposits`）を取り出します。

### 7.5 タグ候補の調査手順

新しい抽出フィールドを追加するとき、タクソノミから適切なタグ名を特定する手順:

**Step 1: ラベルで逆引き（日本語名 → タグ名）**

```bash
# ZIP を一時展開
unzip -o assets/taxonomy/GAAP/JPPFS_20251101.zip -d /tmp/taxonomy

# 日本語ラベルでグレップ
grep -A3 "研究開発費" /tmp/taxonomy/taxonomy/jppfs/2025-11-01/label/jppfs_2025-11-01_lab.xml
```

出力例:
```xml
<link:label xlink:label="label_ResearchAndDevelopmentExpenses" ...>研究開発費</link:label>
<link:labelArc xlink:from="ResearchAndDevelopmentExpenses" xlink:to="label_ResearchAndDevelopmentExpenses"/>
```

→ タグ名は `ResearchAndDevelopmentExpenses`、`.xbrl` 内では `jppfs_cor:ResearchAndDevelopmentExpenses`

**Step 2: タグ名の確認（タグ名 → 日本語ラベル）**

```bash
grep -B3 'xlink:to="label_GrossProfit"' /tmp/taxonomy/taxonomy/jppfs/2025-11-01/label/jppfs_2025-11-01_lab.xml
```

**Step 3: 実際の提出書類での出現確認**

```bash
grep -r "GrossProfit" tmp_cache/edinet/*/XBRL/PublicDoc/*.xbrl | head -5
```

**Step 4: `Constants/Xbrl.swift` に追加**

確認できたタグ名を適切な定数配列に追加します（`.agents/rules/project/constants.md` の「やってはいけないパターン」参照）。

### 7.6 IFRS タグの調べ方

IFRS タグ（`jpigp_cor:*`）は GAAP タクソノミには含まれません。`assets/taxonomy/IFRS/JPIGP_20251101.zip` の `taxonomy/jpigp/2025-11-01/label/jpigp_2025-11-01_lab.xml` を参照してください。

```bash
unzip -o assets/taxonomy/IFRS/JPIGP_20251101.zip -d /tmp/taxonomy_ifrs
grep -A3 "営業利益" /tmp/taxonomy_ifrs/taxonomy/jpigp/2025-11-01/label/jpigp_2025-11-01_lab.xml
```

### 7.7 タクソノミカバレッジ

提出書類で使われる標準タグ（jppfs_cor / jpigp_cor）は JPPFS＋JPIGP の両タクソノミでほぼ全てカバーされる。欠落は `...TextBlock`（注記テキスト格納タグ）のみで、数値 fact ではないためラベル引き・抽出ロジックに影響しない。

