---
name: xbrl-development
description: XBRL 抽出ロジック、Stage、statement・notes・breakdown 契約を追加または変更するときに使う。
---

# XBRL 開発

## 先に読む

- `.agents/rules/xbrl.md`
- `.agents/rules/versioning.md`
- `docs/xbrl-parsing.md`（会計基準・コンテキスト・smoke/golden）
- 配信契約を変える場合は `docs/statement.md` / `docs/breakdown.md` と該当 Contract

## 手順

1. `docs/xbrl-parsing.md` の固定 smoke 企業で実データを取得し、ローカルの `swift test` で床を確認する。
2. 抽出値と元の開示 HTML、コンテキスト、実タグ名を照合する。推測やモックだけで採否を決めない。
3. smoke で拾えない失敗事例を該当 `RealXbrl*Tests.swift` の golden に追加する。新しい note type / breakdown 軸は smoke の床も広げる。
4. 抽出ロジックまたは契約の意味が変わる場合だけ Contract `cache_version` を上げる。細かな連続バンプはマージ前に 1 つへまとめる。
5. ロジックが安定したら disposable Neon へ日経225限定で ingest し、件数・欠測・`needs_review` と `/v1` の配信契約を確認する。
6. 本番 write、公開、対象母集団の拡張はユーザー確認後に `.agents/skills/production-ingest/SKILL.md` に従う。

## 母集団

- statements、financials、filing-sections、breakdowns の business / geography は上場全体が最終母集団。`assets/nikkei225.csv` は処理優先度であり対象限定ではない。
- notes と breakdowns の employees / rd / goodwill は日経225限定。限定実行では `--codes` 等で対象を明示する。
- 最新有報を取得できた会社を分母とし、欠測が正当か抽出不具合かを実データで判定する。
- coverage の分母は最新 120 がある対象社・書類とし、120 がない上場社は含めない。

## 再発防止（Statement）

1. **role 分類**: `Notes*` 接頭辞を先に除外（注記ロールに `BalanceSheet` 等が含まれる）。
2. **連結/非連結**: contextRef で判定。非連結は `isPureNonConsolidatedContext`（セグメント軸付きを拾わない）。
3. **表示順 `order`**: 同一 presentation role 内でのみ比較。代表 role は**出現頻度ではなく採用タグ集合のカバレッジ**。取れないタグはアルファベット順フォールバック。
4. **SS**: 別名 loc をマージし期首→変動→期末の order。連結で個別 SS 由来の stray `ProfitLoss` を除外（個別のみ企業は正当行として残す）。
5. **`section`（BS/CF、科目縦 SS）**: BS/CF は presentation 祖先キーワード。BS 判定順は 純資産→負債→資産（`NetAssets` が `Asset` を部分一致するため）。複数区分に同時一致する祖先は曖昧として上へ。タグ自身名へのフォールバックは単一区分に曖昧さなく一致する場合のみ。US-GAAP 科目縦 SS は区分見出し（資本金 等）を同じキーに載せる（JSON 文字列）。label は開示どおり。
6. **同一タグの二重 loc**: 親候補を集合で持ち BFS。
7. **ラベル**: 提出パッケージ＋ `assets/taxonomy` 補完。`preferredLabel` 対応。期首/期末ラベル差し替えは **CF（と SS）限定**（BS 合計行を巻き込まない）。ロール選択は標準 XBRL ロール優先で決定的に。
8. **CF Instant**: 期首/期末現金は Instant。CF に限り前期 Instant も受理。
9. **`is_total`/`components`**: calculation linkbase（`summation-item`）。presentation の親子では二重計上を防げない。
10. **US-GAAP**: fact 経路不可 → `USGAAPStatementHtml`（当期優先・キヤノン型 components）。表分類・残高・合計の語彙は `USGAAPStatementHtmlVocabulary`（見出しゆれは語を足す。社名 `contains` 分岐は作らない）。分類照合は空白を潰す。取れないときだけ `us_gaap_unsupported`。Summary 用 `USGAAPHtml` と混同しない。

## 再発防止（Breakdown）

1. 比較に必須な揃えは構造側。行ラベル一致は不要。
2. 売上系タグは候補リストで絞る（単一タグ決め打ち不可。IFRS でも表記が割れる）。
3. LLM が効くのは軸判定・変則表。入力帰属が壊れていると救えない。
4. 全社で事業×地域がある前提は置かない。
5. 正規化契約（スキーマ・分母・軸）が本体。LLM は契約への写像補助。
6. 小計・調整行の除外は名称より**数値判定**が頑健。単一セグメントでは数値近似だけで小計扱いにしない。
7. 銀行は `normalizeBankBasis`（分母は segment 小計のうち行合計に最も近い値。単純最大は不可）。単一セグメントは専用タグで検出。
8. 実装コストの重心は geography の `html_table`。`segments` は多くが `xbrl_facts`。
9. `segments` の軸は member 名キーワード。全一致→geography、0一致→business、特定地域名の部分一致のみ混在扱いで `needs_review`（Domestic/Overseas だけの一致では立てない）。
10. 連結優先・非連結フォールバック必須。member ラベル選択は Dictionary 走査順に依存させない。
11. LLM の `profit == nil` だけでは未開示と見落としを区別できない → `profit_disclosed`＋決定的ガード。
12. LLM 行は `cache_version` バンプだけでは再計算しない（`needs_review` または削除）。決定論（`xbrl_facts` / `stacked_segment_pnl` / `not_applicable`）は逆で、`needs_review` だけでは再計算せずバンプ（または欠測・行削除）のみ。`content_hash` は生入力＋分母のみ（プロンプト/モデルを含めない）。
13. 同一表が改ページで `<table>` 分割されることがある。縦（列見出し一致・行ラベルほぼ素・期間同じ）も横（行ラベル一致・右表の合計列が左列＋右の事業列と数値一致）も抽出時に結合する。LLM に複数表から選べと頼まない。
14. 製品・サービス別専用 TextBlock が Prior / Current に分かれるとき、HTML に期間見出しが無い。`contextRef` を `period` にする（地域 dedicated と同じ）。事業セグメント dedicated には付けない。
15. 単一セグメント開示（F）は表が無いときだけ確定する。単一セグメント省略の文言があっても地域別・主要顧客表が残る場合は収益認識の製品別へ寄せる。
16. 同一事業ラベルが指標ブロックごとに繰り返し、末尾「XXX計」だけが指標名を持つ積み上げセグメント損益表（売上高→研究開発費→営業利益等）は、決定論で売上／営業利益ブロックへ行寄せする（`StackedSegmentPnLNormalizer`）。研究開発費ブロックを `profit` に使わない。銘柄特例は作らない。

## Spec 層（テスト資産）

言語が変わっても残る資産と、実装に紐づいて捨ててよい部分を区別する。重要度は層であり、ファイル量ではない。

| 層 | 内容 | 移行耐性 |
|---|---|---|
| **L0 Spec Asset** | 入出力・不変条件・契約・状態規則・期待値 | 残す（トークン理由でも削らない） |
| **L1 Spec Runner** | L0 を接続して走らせる薄い実行器 | 言語ごとに差し替え |
| **L2 Impl Coupling** | 合否に不要な内部型・呼び出し順・FW 固有アサーション | 最小限。捨ててよい |

判定: **実装を消して仕様書だけで同じ合否が書けるか** → Yes なら L0。

| ラベル | 層 | 内容 |
|---|---|---|
| `SPEC_ORACLE` | L0 | 入力→出力の期待値 |
| `SPEC_INVARIANT` | L0 | 常に真であるべき関係 |
| `SPEC_CONTRACT` | L0 | REST の形・エラー意味 |
| `SPEC_POLICY` | L0 | version / skip / floor 等 |
| `HARNESS_ONLY` | L1 | 実行装置 |
| `IMPL_ONLY` | L2 | 実装内部都合のみ（新規禁止） |

**ラベルは L0 の種類。フォルダ名は層ではない。** `Spec/Contract`・`Spec/Policy` 配下の Swift 全体が L0 ではない。

- **L0**: 契約の形・エラー意味・version / skip / floor・JSON 期待値・状態規則そのもの（例: `smoke/*.json`）
- **L1**: in-memory App、ルート叩き、フェイク注入、オラクル突合の実行コード。Vapor 等を使っても、合否定義ではなく実行器なら L1（例: `*OracleFormatTests.swift`、`RoutesTests` の App 起動）
- **L2**: 合否に不要な内部型・呼び出し順・FW 固有の密着。FW を使うこと自体は L2 ではない

削減対象は主に L2 と、過剰な L1 **出力**（成功時の冗長ログ・フル test 出力の文脈投入）。接続テスト本体は残す。

smoke / golden は主に `SPEC_ORACLE` / `SPEC_INVARIANT`（`docs/xbrl-parsing.md` §3）。新規は L0 を厚く（外出し Oracle・床を先に）、床で踏めない分岐だけ golden、L2 は最小。横断一貫性は結合テストではなく `SPEC_INVARIANT` として書く。MCP は製品面にしない（テストも増やさない。既存接続テストは残す）。

## 抽出 how-to（旧 xbrl-parsing）

### EDINET の XBRL 文書構造

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
| `BreakdownExtractor`（`BreakdownExtractor.swift`） | セグメント情報・地域別情報（TextBlock HTML表 → dimension付きfact）。企業間比較向け正規化構想は `docs/breakdown.md` |

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
  5. statement にリース科目が無ければ notes のリースだけ足す
     （`lease_liabilities` 帳簿、または借入金等明細表のリース区分。銀行の `bank_components` も同じ）
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

**Statement**: `USGAAPStatementHtml` が同じ 0105010 HTML 本表から全データ行を
`StatementLineItem` 化する（summary の仮想タグ経路とは別）。
`order` は presentation が無いため HTML 読み順の 0 始まり通し番号（CF/SS の期首→期末もこの順）。
金額は当期半分を優先（富士フイルム入れ子は当期左＝当該科目、キヤノンは金額列／構成比列の左）。
`－`/`-` は 0。`is_total` はラベル規則（「合計」、1文字の「計」、「費用計」、営業/投資/財務CF合計）。表示ラベルは項番・括弧番号を落とす。
`components` は calculation linkbase が無いため、キヤノン型（「…合計」の直後内訳が親金額と
一致）のときだけ合成 tag・weight=+1 で付与する。足し算だけの空番号親は行にしない。
golden: `RealXbrlStatementTests`（S100W3XJ / S100XTLJ / S100YC5C / S100YG81 / S100YD25 / S100YG5L）と `USGAAPStatementHtmlTests`。

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

確認できたタグ名を適切な定数配列に追加します（`.agents/rules/data-handling.md`）。

### 7.6 IFRS タグの調べ方

IFRS タグ（`jpigp_cor:*`）は GAAP タクソノミには含まれません。`assets/taxonomy/IFRS/JPIGP_20251101.zip` の `taxonomy/jpigp/2025-11-01/label/jpigp_2025-11-01_lab.xml` を参照してください。

```bash
unzip -o assets/taxonomy/IFRS/JPIGP_20251101.zip -d /tmp/taxonomy_ifrs
grep -A3 "営業利益" /tmp/taxonomy_ifrs/taxonomy/jpigp/2025-11-01/label/jpigp_2025-11-01_lab.xml
```

### 7.7 タクソノミカバレッジ

提出書類で使われる標準タグ（jppfs_cor / jpigp_cor）は JPPFS＋JPIGP の両タクソノミでほぼ全てカバーされる。欠落は `...TextBlock`（注記テキスト格納タグ）のみで、数値 fact ではないためラベル引き・抽出ロジックに影響しない。

