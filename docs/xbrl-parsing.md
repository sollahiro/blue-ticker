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

`.xbrl` ファイルは、各 `.htm` ファイル内の `ix:nonFraction` タグで定義されたすべての数値を XML に集約したインスタンス文書です。`find_xbrl_files` および `collect_numeric_elements` はこのファイルを対象にします。

**`find_xbrl_files` が返すファイル種別**

| 種別 | 対象 | 除外 |
|---|---|---|
| `.xml` | マニフェスト等のXML | `_lab`, `_pre`, `_cal`, `_def` 付きファイル |
| `.xbrl` | XBRLインスタンス文書 | なし |
| `.htm` / `.html` | **対象外**（HTMLは別途BeautifulSoupでパース） | — |

---

## 2. 会計基準の判定

各モジュールは XBRL タグの有無から会計基準を推定します。`sections.py` の `Section` 基底クラスが構築時に判定し、モジュールに渡します。

### 判定ロジック

```
US-GAAP  ← USGAAP_MARKER_TAGS のいずれかが存在 かつ IFRS マーカーが不在
IFRS     ← IFRS_BALANCE_SHEET_MARKER_TAGS または IFRS_PL_MARKER_TAGS が存在
J-GAAP   ← 上記いずれにも該当しない
```

### US-GAAP判定マーカータグ（`USGAAP_MARKER_TAGS`）

```
TotalAssetsUSGAAPSummaryOfBusinessResults
EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults
CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults
RevenuesUSGAAPSummaryOfBusinessResults
NetIncomeLossAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults
CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults
CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults
```

> **注意**: IFRSへ移行済みの企業でも、過去比較データとして `*USGAAP*` タグが残存することがあります。「USGAAPタグが存在してもIFRSマーカーがあれば IFRS と判定」という 2 段階チェックを行っています。

### IFRSマーカータグ（BS系: `IFRS_BALANCE_SHEET_MARKER_TAGS`）

```
InterestBearingLiabilitiesCLIFRS / InterestBearingLiabilitiesNCLIFRS
BorrowingsCLIFRS / BorrowingsNCLIFRS
BondsPayableNCLIFRS
BondsAndBorrowingsCLIFRS / BondsAndBorrowingsNCLIFRS
BondsBorrowingsAndLeaseLiabilitiesCLIFRS / BondsBorrowingsAndLeaseLiabilitiesNCLIFRS
```

### IFRSマーカータグ（PL系: `IFRS_PL_MARKER_TAGS`）

BS系より広く、PL/CF のデータタグ自体もマーカーとして機能します。これにより `pre_parsed` 経由で BS 側タグが収集対象に含まれない場合でも IFRS 判定を維持します。

```
InterestBearingLiabilitiesCLIFRS / BorrowingsCLIFRS / BondsPayableNCLIFRS / BorrowingsNCLIFRS
NetSalesIFRS / RevenueIFRS / GrossProfitIFRS
SellingGeneralAndAdministrativeExpensesIFRS / OperatingProfitLossIFRS
OperatingRevenuesIFRSKeyFinancialData
ProfitLossAttributableToOwnersOfParentIFRS / ProfitLossAttributableToOwnersOfParentIFRSSummaryOfBusinessResults
CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults
CashFlowsFromUsedInInvestingActivitiesIFRSSummaryOfBusinessResults
```

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

### 3.2 コンテキストパターン（`constants/xbrl.py`）

**Duration コンテキスト（損益計算書・CF計算書）**

| 定数名 | パターン | 意味 |
|---|---|---|
| `DURATION_CONTEXT_PATTERNS` | `CurrentYearDuration` | 連結 当期（年次通期） |
| | `FilingDateDuration` | 連結 当期（提出日基準） |
| | `InterimDuration` | 連結 当期（新形式 中間期） |
| | `CurrentYTDDuration` | 連結 当期（旧形式 中間・四半期累計） |
| `PRIOR_DURATION_CONTEXT_PATTERNS` | `Prior1YearDuration` | 連結 前期（年次） |
| | `PriorYearDuration` | 連結 前期（年次 別名） |
| | `Prior1InterimDuration` | 連結 前期（中間期） |
| | `Prior1YTDDuration` | 連結 前期（累計） |

**Instant コンテキスト（貸借対照表）**

| 定数名 | パターン | 意味 |
|---|---|---|
| `INSTANT_CONTEXT_PATTERNS` | `CurrentYearInstant` | 連結 当期末 |
| | `CurrentQuarterInstant` | 連結 当期末（四半期） |
| | `InterimInstant` | 連結 当期末（中間期） |
| | `FilingDateInstant` | 連結 当期末（提出日基準） |
| `PRIOR_INSTANT_CONTEXT_PATTERNS` | `Prior1YearInstant` | 連結 前期末 |
| | `PriorYearInstant` | 連結 前期末（別名） |
| | `Prior1QuarterInstant` | 連結 前期末（四半期） |
| | `Prior1InterimInstant` | 連結 前期末（中間期） |

`_NonConsolidated` が含まれるコンテキストは個別財務諸表の値です。

---

## 4. 解析モジュール一覧

### 4.1 セクション型アーキテクチャ

各 `extract_*` 関数は `Section` オブジェクトを受け取ります（`analysis/sections.py`）。`Section` は構築時に XBRL から関連タグを収集・正規化し、会計基準を判定した上で `FieldSet`（`{tag: value}` の辞書）を保持します。これにより各モジュールは会計基準判定・コンテキスト解決を意識せず、タグ名の優先順リストを渡すだけで値を取得できます。

**Section の種別**

| クラス | 期間種別 | 主な用途 |
|---|---|---|
| `IncomeStatementSection` | Duration | 損益計算書・CF内の損益系項目 |
| `CashFlowSection` | Duration | CF計算書・株主資本変動計算書 |
| `BalanceSheetSection` | Instant | 貸借対照表 |
| `EquityStatementSection` | Duration | 株主資本等変動計算書（IFRS） |
| `EmployeeSection` | Instant | 従業員の状況（連結優先・個別フォールバック） |

### 4.2 モジュール一覧

| extract関数 | ファイル | Sectionの種別 | 抽出内容 |
|---|---|---|---|
| `extract_income_statement` | `income_statement.py` | IncomeStatement | 売上高・営業利益・純利益・会計基準 |
| `extract_gross_profit` | `gross_profit.py` | IncomeStatement | 売上総利益（直接法→計算法のフォールバック） |
| `extract_operating_profit` | `operating_profit.py` | IncomeStatement | 営業利益（直接法→GP-SGA計算法のフォールバック） |
| `extract_interest_expense` | `interest_expense.py` | IncomeStatement | 支払利息 |
| `extract_tax_expense` | `tax_expense.py` | IncomeStatement | 税引前利益・法人税等・実効税率 |
| `extract_research_development` | `research_development.py` | IncomeStatement | 研究開発費 |
| `extract_net_revenue` | `net_revenue.py` | IncomeStatement | IFRS金融会社向け純収益・事業利益 |
| `extract_cash_flow` | `cash_flow.py` | CashFlow | 営業CF・投資CF |
| `extract_capital_expenditure` | `capital_expenditure.py` | CashFlow | 設備投資額（設備投資等概要→CF順） |
| `extract_share_buyback` | `share_buyback.py` | CashFlow | 自己株式取得額（CF→株主資本変動計算書順） |
| `extract_balance_sheet` | `balance_sheet.py` | BalanceSheet | 総資産・流動/固定資産・流動/固定負債・純資産 |
| `extract_interest_bearing_debt` | `interest_bearing_debt.py` | BalanceSheet | 有利子負債合計（直接法→積み上げ法のフォールバック） |
| `extract_tangible_fixed_assets` | `tangible_fixed_assets.py` | BalanceSheet | 有形固定資産合計・内訳 |
| `extract_bank_financials` | `bank_financials.py` | BalanceSheet | 銀行業固有BS項目（預金・貸出金等） |
| `extract_employees` | `employees.py` | Employee | 従業員数（連結→個別フォールバック） |
| `extract_order_book` | `order_book.py` | IncomeStatement | 受注高・受注残高 |
| `extract_shareholder_metrics` | `shareholder_metrics.py` | （複合） | 株価・PBR・BPS・DPS等の株主指標 |
| `extract_segment_info` / `extract_geography_info` | `segment_extractor.py` | — | セグメント情報・地域別情報（直接HTMLパース） |

### 4.3 売上総利益（`gross_profit.py`）

```
US-GAAP → usgaap/gross_profit.py の HTML パース（§5 参照）

J-GAAP / IFRS:
  1. 直接法: GROSS_PROFIT_DIRECT_TAGS を検索
     - GrossProfitIFRS（IFRS連結）
     - GrossProfit（J-GAAP連結）
     - GrossProfitOnCompletedConstructionContractsCNS（建設業）
     - OperatingGrossProfit（倉庫・運輸等 J-GAAP 営業総利益）
  2. 計算法: 売上高タグ − 売上原価タグ（直接法で取得できなかった場合）
     - GROSS_PROFIT_COMPONENT_DEFINITIONS 参照
  3. 銀行業: BUSINESS_GROSS_PROFIT_COMPONENT_DEFINITIONS（収益/費用の符号付き合算）
  4. 連結値がなければ個別値にフォールバック
```

### 4.4 有利子負債（`interest_bearing_debt.py`）

```
US-GAAP → BalanceSheetSection 経由で USGAAP_HTML_IBDCurrent / IBDNonCurrent を取得（§5 参照）
銀行業  → BANK_IBD_COMPONENT_DEFINITIONS（預金・借用金等の銀行固有コンポーネント）

J-GAAP / IFRS:
  1. 直接法: INTEREST_BEARING_DEBT_TAGS（InterestBearingDebt / InterestBearingLiabilities）
  2. 積み上げ法: IBD_CURRENT_COMPONENTS + IBD_NON_CURRENT_COMPONENTS（7〜9コンポーネント）
     - J-GAAP/IFRS 両タグを優先順で試行（ShortTermLoansPayable → BorrowingsCLIFRS 等）
     - リース負債（LeaseObligationsCL / NCL）も含む
  3. IFRS集約タグ: 粒度別タグ不在時は IBD_IFRS_CL_TAGS / IBD_IFRS_NCL_TAGS で代替
     （BondsAndBorrowingsCLIFRS / BondsBorrowingsAndLeaseLiabilitiesCLIFRS 等）
  4. 連結値がなければ個別値にフォールバック
```

### 4.5 営業利益（`operating_profit.py`）

```
1. 直接法: OPERATING_PROFIT_DIRECT_TAGS
   - OperatingProfitLossIFRS（IFRS）
   - OperatingIncomeLoss / OperatingIncome（J-GAAP）
   - USGAAP_HTML_OperatingIncome（US-GAAP仮想タグ、§5 参照）
2. 計算法: GrossProfit − SGA（IFRS で OperatingProfitLossIFRS が存在しない日立等向け）
   - SGA は SellingGeneralAndAdministrativeExpensesIFRS / JGAAP を直接取得
   - または SellingExpensesIFRS + GeneralAndAdministrativeExpensesIFRS を合算
3. 経常利益フォールバック: ORDINARY_INCOME_TAGS（J-GAAP 金融機関向け）
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

US-GAAP HTML パースの結果は **仮想タグ** として `FieldSet` に注入されます。仮想タグを受け取る各 `extract_*` 関数は、仮想タグを通常の XBRL タグと同列に扱うだけでよく、US-GAAP 固有の処理を意識しません。

```
HTML パース（usgaap/html_fields.py）
  → USGAAP_HTML_CurrentAssets / CurrentLiabilities / ...
  → USGAAP_HTML_PPENet / BuildingsGross / MachineryGross / ...
  → USGAAP_HTML_IBDCurrent / IBDNonCurrent
  → USGAAP_HTML_OperatingIncome / SGA / PreTaxIncome / ...

FieldSet に merge（Section の from_xbrl 内）
  ↓
extract_balance_sheet / extract_interest_bearing_debt 等が
通常の J-GAAP / IFRS タグと同じ優先順リストで解決
```

注入は `sections.py` の各 `Section.from_xbrl` で行われます。US-GAAP と判定された場合に `parse_usgaap_html_bs_fields` / `parse_usgaap_html_pl_fields` / `parse_usgaap_html_equity_cf_fields` を呼び出して `FieldSet` に追記します。

### 5.3 `usgaap/html_fields.py` のカバー範囲

| 関数 | 対象ファイル | 生成する仮想タグ（主要） |
|---|---|---|
| `parse_usgaap_html_bs_fields` | `0105010_*_ixbrl.htm` | CurrentAssets / NonCurrentLiabilities / PPENet / IBDCurrent / IBDNonCurrent / NetAssets 等 |
| `parse_usgaap_html_pl_fields` | `0105010_*_ixbrl.htm` | OperatingIncome / SGA / PreTaxIncome / IncomeTax 等 |
| `parse_usgaap_html_equity_cf_fields` | `0105010_*_ixbrl.htm` | 株主資本変動計算書の自己株式取得・処分等 |

HTMLテーブルのラベル文字列 → 仮想タグ名のマッピングは `html_fields.py` 冒頭の辞書（`_BS_LABEL_MAP` 等）で一元管理されています。

### 5.4 売上総利益のHTMLパース（`usgaap/gross_profit.py`）

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

```python
# colspan展開で物理列インデックスを算出（ヘッダーセルのspan-1が合計列）
col_offset = 0
for cell in header_cells:
    span = int(cell.get("colspan", 1))
    last_col = col_offset + span - 1   # colspan=2 なら offset+1 が合計列
    if "当連結" in cell.get_text():
        current_col_idx = last_col
    elif "前連結" in cell.get_text():
        prior_col_idx = last_col
    col_offset += span

# 最近傍マッチ（単純な「<=2」ではなく最小距離を選択）
def _find_nearest(target_col):
    best_val, best_dist = None, float("inf")
    for i, v in numerics:
        d = abs(i - target_col)
        if d < best_dist:
            best_dist, best_val = d, v
    return best_val if best_dist <= 2 else None
```

### 5.5 支払利息のHTMLパース（`usgaap/interest_expense.py`）

US-GAAP 企業では `ix:nonFraction` が存在しないため、連結損益計算書 HTML から支払利息を取得します。`parse_usgaap_html_pl_fields` が生成する `USGAAP_HTML_` 系仮想タグには支払利息が含まれないため、`extract_usgaap_ie_from_html` が個別に HTMLパースを行います（注記セクションを検索）。

---

## 6. スモークテスト

### 6.1 構成

スモークテストは `smoke/` ディレクトリ以下で管理します（テストフレームワークとは独立）。

```
smoke/
  _common.py             # 各企業のXBRLキャッシュから全抽出器を実行して結果を返す共通処理
  check.py               # 年次スモーク実行スクリプト
  check_half.py          # 半期スモーク実行スクリプト
  smoke_expected/        # 年次期待値 JSON（{code}_{fy_end}.json）
  smoke_half_expected/   # 半期期待値 JSON
  smoke-field-values.md  # フィールド一覧とスモークテストの仕様説明
```

期待値 JSON を更新するには実際に実行して差分を確認し、正しければ上書きします。

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
