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

各モジュールは XBRL タグの有無から会計基準を推定します。

### 判定ロジック

```
US-GAAP  ← *USGAAPSummaryOfBusinessResults タグが存在 かつ IFRSマーカーが不在
IFRS     ← IFRS識別タグ（BorrowingsCLIFRS 等）が存在
J-GAAP   ← 上記いずれにも該当しない
```

### IFRS判定マーカータグ

BS/IBD 系モジュールは貸借対照表タグを広めに見ます。

```
InterestBearingLiabilitiesCLIFRS
InterestBearingLiabilitiesNCLIFRS
BorrowingsCLIFRS
BondsPayableNCLIFRS
BorrowingsNCLIFRS
BondsAndBorrowingsCLIFRS
BondsAndBorrowingsNCLIFRS
```

GP/OP/CF 系モジュールは、既存のPL/CF抽出に必要な最小セットを使います。

```
InterestBearingLiabilitiesCLIFRS
BorrowingsCLIFRS
BondsPayableNCLIFRS
BorrowingsNCLIFRS
```

IE/DA/TAX などは、上記に各モジュール自身の IFRS タグ
（例: `FinanceCostsIFRS`, `DepreciationAndAmortizationOpeCFIFRS`,
`ProfitLossBeforeTaxIFRS`）を加えて判定します。これにより、貸借対照表側の
マーカーが収集対象に存在しない `pre_parsed` 入力でも IFRS 判定を維持します。

### US-GAAP判定マーカータグ

```
TotalAssetsUSGAAPSummaryOfBusinessResults
EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults
CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults
```

> **注意**: IFRSへ移行済みの企業でも、過去比較データとして `*USGAAP*` タグが残存することがあります。各モジュールでは「USGAAPタグが存在してもIFRSマーカーがあれば IFRS と判定」という 2 段階チェックを行っています。

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

### 3.2 よく使われるコンテキスト名

**Duration コンテキスト（損益計算書・CF計算書）**

| コンテキスト名（部分一致） | 意味 |
|---|---|
| `CurrentYearDuration` | 連結 当期（年次） |
| `FilingDateDuration` | 連結 当期（提出日基準） |
| `InterimDuration` | 連結 当期（新形式 中間期） |
| `CurrentYTDDuration` | 連結 当期（旧形式 中間・四半期累計） |
| `Prior1YearDuration` | 連結 前期（年次） |
| `PriorYearDuration` | 連結 前期（年次 別名） |
| `Prior1InterimDuration` | 連結 前期（中間期） |
| `Prior1YTDDuration` | 連結 前期（累計） |

`_NonConsolidated` が含まれるコンテキストは個別財務諸表の値です。

**Instant コンテキスト（貸借対照表）**

| コンテキスト名（部分一致） | 意味 |
|---|---|
| `CurrentYearInstant` | 連結 当期末 |
| `FilingDateInstant` | 連結 当期末（提出日基準） |
| `Prior1YearInstant` | 連結 前期末 |
| `PriorYearInstant` | 連結 前期末（別名） |

---

## 4. 各モジュールの抽出戦略

### 4.1 モジュール一覧

| モジュール | ファイル | コンテキスト | 対象財務諸表 |
|---|---|---|---|
| 売上総利益 | `analysis/gross_profit.py` | Duration | 連結損益計算書 |
| キャッシュフロー | `analysis/cash_flow.py` | Duration | 連結CF計算書 |
| 有利子負債 | `analysis/interest_bearing_debt.py` | Instant | 連結貸借対照表 |
| 従業員数 | `analysis/employees.py` | Instant | 連結（個別フォールバック） |
| IFRS純収益 | `analysis/net_revenue.py` | Duration | IFRS金融会社向け代替収益 |

### 4.2 売上総利益（`gross_profit.py`）

```
1. US-GAAP → 0105010 HTML をパース（§5 参照）
2. J-GAAP / IFRS
   a. 直接法: GrossProfitIFRS / GrossProfit タグを検索
   b. 計算法: 売上高タグ − 売上原価タグ（直接法で取得できなかった場合）
   c. 連結値がなければ個別値にフォールバック
```

**直接法タグ**

| タグ | 会計基準 |
|---|---|
| `GrossProfitIFRS` | IFRS連結 |
| `GrossProfit` | J-GAAP連結 |

**計算法コンポーネント**

| ラベル | タグ候補（優先順） |
|---|---|
| 売上高 | `NetSalesIFRS`, `NetSales`, `Revenue` |
| 売上原価 | `CostOfSalesIFRS`, `CostOfSales` |

### 4.3 キャッシュフロー（`cash_flow.py`）

```
1. 営業CF・投資CF それぞれのタグリストを順に検索（直接法のみ）
2. 連結当期の Duration コンテキストに一致する値を返す
```

**営業CF タグ候補**

| タグ | 会計基準・出典 |
|---|---|
| `NetCashProvidedByUsedInOperatingActivities` | J-GAAP 連結CF計算書 |
| `NetCashProvidedByUsedInOperatingActivitiesSummaryOfBusinessResults` | J-GAAP 決算短信 |
| `CashFlowsFromUsedInOperationsIFRS` | IFRS（間接法） |
| `CashFlowsFromUsedInOperatingActivitiesIFRS` | IFRS（直接法） |
| `CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults` | IFRS 決算短信 |

### 4.4 有利子負債（`interest_bearing_debt.py`）

```
1. US-GAAP → 0105020 HTML 借入金ノートをパース（§5 参照）
2. J-GAAP / IFRS
   a. 直接法: InterestBearingDebt / InterestBearingLiabilities タグを検索
   b. 積み上げ法: 7コンポーネントを個別取得して合算
   c. IFRS集約タグ: 粒度別タグ不在時は CurrentPortionOfLongTermDebtCLIFRS 等で代替
   d. 連結値がなければ個別値にフォールバック
```

**IBDコンポーネント（積み上げ法）**

| コンポーネント | J-GAAPタグ | IFRSタグ |
|---|---|---|
| 短期借入金 | `ShortTermLoansPayable` | `BorrowingsCLIFRS` |
| コマーシャル・ペーパー | `CommercialPapersLiabilities` | `CommercialPapersCLIFRS` |
| 短期社債 | `ShortTermBondsPayable` | — |
| 1年内償還予定の社債 | `CurrentPortionOfBonds` | `CurrentPortionOfBondsCLIFRS` |
| 1年内返済予定の長期借入金 | `CurrentPortionOfLongTermLoansPayable` | `CurrentPortionOfLongTermBorrowingsCLIFRS` |
| 社債 | `BondsPayable` | `BondsPayableNCLIFRS` |
| 長期借入金 | `LongTermLoansPayable` | `BorrowingsNCLIFRS` |

**IFRS集約タグ**

| タグ | 代替する個別コンポーネント |
|---|---|
| `CurrentPortionOfLongTermDebtCLIFRS` | 1年内社債 + 1年内長期借入金 |
| `BondsAndBorrowingsCLIFRS` | 同上（別名） |
| `LongTermDebtNCLIFRS` | 社債 + 長期借入金 |
| `BondsAndBorrowingsNCLIFRS` | 同上（別名） |

---

## 5. US-GAAP 固有の制約と HTML パース

### 5.1 US-GAAP 企業の XBRL 上の制約

US-GAAP 採用企業（例: 富士フイルム 4901）では、**連結財務諸表（0105010）に `ix:nonFraction` タグが存在しません**。これは EDINET の iXBRL 対応が US-GAAP の連結勘定科目に未対応であるためです。

```
0101010 (決算短信サマリー)   → *USGAAPSummaryOfBusinessResults タグあり（売上高等）
0105010 (連結財務諸表)      → ix:nonFraction タグなし（純 HTML テーブル）
0105020 (個別財務諸表)      → 借入金関連の XBRL タグあり（注記セクション）
```

このため、US-GAAP 企業の**売上総利益・有利子負債は XBRL からは取得できず**、HTML をパースする必要があります。

### 5.2 売上総利益のHTMLパース（`_extract_usgaap_gp_from_html`）

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
- `前期合計` / `当期合計` がそれぞれ前期・当期の値
- ヘッダーの `colspan` を展開して列インデックスを特定し、最近傍マッチで値を取り出す

**実装上のポイント**

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

### 5.3 有利子負債のHTMLパース（`_extract_usgaap_from_html`）

**対象ファイル**: `0105020_*_ixbrl.htm`（連結財務諸表注記）のうち借入金セクション

**セクション検索キーワード**: `短期借入金の残高` または `短期の社債及び借入金`

**富士フイルム方式のテーブル（US-GAAP集約形式）**

```
ヘッダー: | 前連結会計年度末(百万円) | 当連結会計年度末(百万円) |
データ:   | 合計          | xxx,xxx | xxx,xxx |   ← 短期の社債及び借入金 合計
          | 差引計         | xxx,xxx | xxx,xxx |   ← 長期の社債及び借入金 差引計（1年内除く）
```

`合計（短期）＋差引計（長期）` で有利子負債合計を計算します。

**ヘッダー形式**

企業によってヘッダー形式が異なるため、2パターンに対応しています。

| パターン | 例 |
|---|---|
| 期番号形式 | `第87期末（百万円）`, `第88期末（百万円）` |
| 連結会計年度形式 | `前連結会計年度末(百万円)`, `当連結会計年度末(百万円)` |

**ヘッダー行の自動検出**

空行（全セルが空）をスキップし、`第` / `前連結会計年度` / `当連結会計年度` のいずれかを含む行をヘッダーとみなします。

---

## 6. 実装ガイドライン

### 6.1 EDINET-onlyスモークの対象企業

EDINET-onlyスモークは、実企業の `search_*.json` と展開済み `{docID}_xbrl/` だけを使い、ネットワークや通常の分析結果キャッシュに依存せずに XBRL parse と主要抽出器を検証します。

対象企業の正本は `blue_ticker/services/edinet_smoke_cache.py` の `DEFAULT_SMOKE_COMPANIES` です。実テスト側では `tests/test_edinet_only_cached_smoke.py` が同じ一覧を参照し、会計基準の期待値だけを付与します。会計基準変更やテスト対象の見直しは、原則としてこの企業一覧と期待値表をあわせて更新してください。

| コード | 企業 | 区分 | 調べること |
|---|---|---|---|
| `4901` | 富士フイルム | `US-GAAP` | US-GAAP企業の制約確認。連結財務諸表側に通常の `ix:nonFraction` がなく、売上総利益・有利子負債を HTML パースで補う経路を検証する。 |
| `7751` | キヤノン | `US-GAAP/IFRS boundary` | US-GAAP から IFRS への会計基準移行境界を確認する。テストでは期末が `2026-12-31` 以前なら US-GAAP、それ以降なら IFRS を期待する。 |
| `8306` | 三菱UFJ | `J-GAAP financial` | J-GAAP金融会社の確認。銀行系は通常事業会社と財務諸表構造が異なるため、PL/BS抽出と会計基準判定を通しつつ、売上総利益・有利子負債の未検出を許容する。 |
| `8316` | 三井住友 | `J-GAAP financial` | J-GAAP金融会社の確認。銀行系の実企業データで、PL/BS抽出と会計基準判定が崩れないことを見る。 |
| `6103` | オークマ | `J-GAAP operating` | 通常のJ-GAAP事業会社を確認する。標準的な営業会社で、PL/BS/売上総利益/有利子負債抽出が通ることを見る。 |
| `6326` | クボタ | `IFRS` | IFRS事業会社の確認。IFRSタグ体系でPL/BS/売上総利益/有利子負債抽出が通ることを見る。 |
| `2802` | 味の素 | `IFRS` | IFRS事業会社の確認。`GrossProfitIFRS` の直接取得と、IFRS有利子負債でリース債務など一部タグ粒度が不足するケースを意識して検証する。 |
| `7269` | スズキ | `IFRS/J-GAAP boundary` | J-GAAP から IFRS への会計基準移行境界を確認する。テストでは期末が `2024-03-31` 以前なら J-GAAP、それ以降なら IFRS を期待する。 |
| `7422` | 東邦レマック | `J-GAAP nonconsolidated` | 連結財務諸表がないJ-GAAP企業の確認。`has_nonconsolidated_contexts` が False になり、単体のみ企業として個別財務諸表へフォールバックできることを見る。 |
| `3490` | アズ企画設計 | `J-GAAP nonconsolidated/consolidated boundary` | 連結財務諸表の作成開始境界を確認する。2024年2月期から連結作成のため、期末が `2024-02-29` 以降なら `has_nonconsolidated_contexts` が True になることを見る。 |

スモークで必ず確認する抽出器は、損益計算書、貸借対照表、売上総利益、有利子負債です。損益計算書と貸借対照表は少なくとも主要値のいずれかが取れることを確認し、売上総利益と有利子負債は金融会社だけ `not_found` を許容します。連結/個別判定の実データ回帰対象では、抽出器を呼ぶ前に `has_nonconsolidated_contexts(pre_parsed)` の期待値も検証します。

---

