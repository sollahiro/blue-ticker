"""
有利子負債 XBRL 抽出 - 試験的実装

XBRLインスタンス文書から有利子負債を構成要素ごとに抽出する PoC。

有利子負債の定義:
  短期借入金
  + コマーシャル・ペーパー
  + 1年内償還予定の社債
  + 1年内返済予定の長期借入金
  + 社債
  + 長期借入金
  + 短期リース債務
  + 長期リース債務

タグ体系:
  J-GAAP: ShortTermLoansPayable, BondsPayable, LongTermLoansPayable, ...
  IFRS連結: BorrowingsCLIFRS, BondsPayableNCLIFRS, BorrowingsNCLIFRS, ...
  ※ 両方を候補として保持し、見つかった方を採用する

抽出戦略:
  1. 直接法: InterestBearingDebt タグを検索
  2. 積み上げ法: 各コンポーネントを個別に取得して合算

既知の制約:
  - IFRS採用企業では、リース債務が OtherFinancialLiabilities{CL/NCL}IFRS に
    埋め込まれており、専用タグが存在しないケースがある。
    （例: 2802 味の素。報告書記載の有利子負債4,960億円に対し、
          XBRL抽出では約377億円のリース債務が取れず4,583億円となる）
  - その場合、個別（非連結）のリース債務タグにフォールバックするが、
    連結値と乖離する可能性がある。
  - 全社がIFRSとは限らないため、この割り切りは許容範囲とする。
"""

import re
import unittest
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional

try:
    from bs4 import BeautifulSoup
    _BS4_AVAILABLE = True
except ImportError:
    _BS4_AVAILABLE = False


# ---------------------------------------------------------------------------
# 試験的実装（本番コードに移行する前の PoC）
# ---------------------------------------------------------------------------

# 有利子負債合計タグ（直接法で使うタグ）
INTEREST_BEARING_DEBT_TAGS = [
    "InterestBearingDebt",
    "InterestBearingLiabilities",
]

# 各コンポーネントのラベルと候補タグ名（J-GAAP → IFRS の優先順）
# 複数候補がある場合、最初に見つかったものを採用する
COMPONENT_DEFINITIONS = [
    {
        "label": "短期借入金",
        "tags": [
            "ShortTermLoansPayable",        # J-GAAP
            "BorrowingsCLIFRS",             # IFRS 流動負債 借入金
        ],
    },
    {
        "label": "コマーシャル・ペーパー",
        "tags": [
            "CommercialPapersLiabilities",  # J-GAAP
            "CommercialPapersCLIFRS",       # IFRS
        ],
    },
    {
        "label": "1年内償還予定の社債",
        "tags": [
            "CurrentPortionOfBonds",                    # J-GAAP
            "RedeemableBondsWithinOneYear",             # J-GAAP 別名
            "CurrentPortionOfBondsCLIFRS",              # IFRS
        ],
    },
    {
        "label": "1年内返済予定の長期借入金",
        "tags": [
            "CurrentPortionOfLongTermLoansPayable",     # J-GAAP
            "CurrentPortionOfLongTermBorrowingsCLIFRS", # IFRS 粒度別
        ],
    },
    {
        "label": "社債",
        "tags": [
            "BondsPayable",                 # J-GAAP
            "BondsPayableNCLIFRS",          # IFRS 非流動負債
        ],
    },
    {
        "label": "長期借入金",
        "tags": [
            "LongTermLoansPayable",         # J-GAAP
            "BorrowingsNCLIFRS",            # IFRS 非流動負債 借入金
        ],
    },
]

# 複数の構成要素を集約したIFRSタグ。
# 粒度別タグが存在しない場合に、カバーする個別コンポーネントを置き換える。
# 例: 日立は BondsPayableNCLIFRS/BorrowingsNCLIFRS の代わりに LongTermDebtNCLIFRS を使用。
AGGREGATE_IFRS_DEFINITIONS = [
    {
        "tag": "CurrentPortionOfLongTermDebtCLIFRS",  # 1年内長期有利子負債（社債+借入金を集約）
        "covers": ["1年内償還予定の社債", "1年内返済予定の長期借入金"],
    },
    {
        "tag": "LongTermDebtNCLIFRS",                 # 長期有利子負債（社債+借入金を集約）
        "covers": ["社債", "長期借入金"],
    },
]

# contextRef で連結期末時点を表すパターン
# _NonConsolidatedMember を含むものは個別決算 → 連結を優先するため除外
INSTANT_CONTEXT_PATTERNS = [
    "CurrentYearInstant",
    "FilingDateInstant",
]

PRIOR_CONTEXT_PATTERNS = [
    "Prior1YearInstant",
    "PriorYearInstant",
]


def _is_consolidated_instant(ctx: str) -> bool:
    """連結の期末残高コンテキストかどうか。"""
    return (
        any(p in ctx for p in INSTANT_CONTEXT_PATTERNS)
        and "_NonConsolidated" not in ctx
    )


def _is_consolidated_prior(ctx: str) -> bool:
    """連結の前期末残高コンテキストかどうか。"""
    return (
        any(p in ctx for p in PRIOR_CONTEXT_PATTERNS)
        and "_NonConsolidated" not in ctx
    )


def _is_nonconsolidated_instant(ctx: str) -> bool:
    """個別の期末残高コンテキストかどうか。"""
    return (
        any(p in ctx for p in INSTANT_CONTEXT_PATTERNS)
        and "_NonConsolidated" in ctx
    )


def _is_nonconsolidated_prior(ctx: str) -> bool:
    """個別の前期末残高コンテキストかどうか。"""
    return (
        any(p in ctx for p in PRIOR_CONTEXT_PATTERNS)
        and "_NonConsolidated" in ctx
    )


def _parse_value(text: Optional[str]) -> Optional[float]:
    """XBRL数値テキストを float に変換。"""
    if not text or text.strip() in ("", "nil"):
        return None
    try:
        return float(text.strip())
    except (ValueError, TypeError):
        return None


def _collect_numeric_elements(xml_file: Path) -> dict:
    """XMLファイルから {local_tag: {ctx: value}} の辞書を返す。"""
    results: dict = {}
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        for elem in root.iter():
            tag = elem.tag
            local_tag = tag.split("}")[1] if "}" in tag else tag
            ctx = elem.attrib.get("contextRef", "")
            value = _parse_value(elem.text)
            if value is not None and ctx:
                if local_tag not in results:
                    results[local_tag] = {}
                results[local_tag][ctx] = value
    except ET.ParseError:
        pass
    return results


def _find_consolidated_value(tag_elements: dict, tag: str) -> tuple[Optional[float], Optional[float]]:
    """指定タグの連結当期・前期値のみを返す（個別へのフォールバックなし）。"""
    if tag not in tag_elements:
        return None, None
    current = prior = None
    for ctx, val in tag_elements[tag].items():
        if _is_consolidated_instant(ctx):
            current = val
        elif _is_consolidated_prior(ctx):
            prior = val
    return current, prior


def _find_nonconsolidated_value(tag_elements: dict, tag: str) -> tuple[Optional[float], Optional[float]]:
    """指定タグの個別当期・前期値のみを返す。"""
    if tag not in tag_elements:
        return None, None
    current = prior = None
    for ctx, val in tag_elements[tag].items():
        if _is_nonconsolidated_instant(ctx):
            current = val
        elif _is_nonconsolidated_prior(ctx):
            prior = val
    return current, prior


def _parse_number(text: str) -> Optional[float]:
    """HTML表セルの数値テキストをfloatに変換（百万円単位のまま）。
    "22,548" → 22548.0, "22,548百万円" → 22548.0, "－" → None
    """
    if not text:
        return None
    text = text.strip()
    # 「百万円」「億円」等の単位サフィックスを除去（長い単位から順にマッチ）
    text = re.sub(r'(百万円|十万円|億円|兆円|千円|百円|万円|円)$', '', text).strip()
    text = text.replace(",", "").replace("，", "")
    if text in ("－", "-", "―", "—", ""):
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _determine_column_order(headers: list[str]) -> tuple[int, int]:
    """
    ['第87期末（百万円）', '第88期末（百万円）'] のようなヘッダリストから
    (prior_col_idx, current_col_idx) を返す。
    期番号が大きい方がcurrent。ヘッダが1つ以下の場合は (None, 0)。
    """
    period_nums = []
    for h in headers:
        m = re.search(r'第(\d+)期', h)
        period_nums.append(int(m.group(1)) if m else -1)
    if len(period_nums) < 2:
        return None, 0
    if period_nums[0] > period_nums[1]:
        return 1, 0   # col0=current, col1=prior → prior=1, current=0
    else:
        return 0, 1   # col0=prior, col1=current


def _find_loan_section_pos(content: str) -> int:
    """
    借入金ノートセクションの開始位置を返す。見つからない場合 -1。
    年度・会社によって注記番号・見出し名が異なるため、
    セクション本文冒頭の「短期借入金の残高」フレーズで一律に検索する。
    """
    idx = content.find("短期借入金の残高")
    if idx >= 0:
        nearby = content[idx: idx + 200]
        if "該当事項" not in nearby:
            return idx
    return -1


def _parse_loan_tables(tables: list) -> dict:
    """
    パース済みテーブルリストから借入金各要素を抽出して返す。
    Returns: {short_term, lt_total, lt_1yr, bonds} の各 (current, prior) タプル辞書
    """
    short_term_current = short_term_prior = None
    lt_total_current = lt_total_prior = None
    lt_1yr_current = lt_1yr_prior = None
    bonds_current = bonds_prior = None

    for tbl in tables:
        headers = tbl["headers"]
        rows = tbl["rows"]
        if not rows:
            continue

        prior_idx, current_idx = _determine_column_order(headers[1:])

        for row in rows:
            if not row or len(row) < 2:
                continue
            label = row[0]
            vals = row[1:]

            def _get(idx):
                if idx is None or idx >= len(vals):
                    return None
                return _parse_number(vals[idx])

            if "短期借入金" in label and "（" not in label and "１年" not in label and "1年" not in label:
                short_term_current = short_term_current or _get(current_idx)
                short_term_prior   = short_term_prior   or _get(prior_idx)

            elif re.match(r'^長期借入金$', label):
                lt_total_current = lt_total_current or _get(current_idx)
                lt_total_prior   = lt_total_prior   or _get(prior_idx)

            elif "１年以内返済" in label or "1年以内返済" in label or "うち１年" in label:
                lt_1yr_current = lt_1yr_current or _get(current_idx)
                lt_1yr_prior   = lt_1yr_prior   or _get(prior_idx)

            elif "社債計" in label:
                bonds_current = bonds_current or _get(current_idx)
                bonds_prior   = bonds_prior   or _get(prior_idx)

    return {
        "short_term": (short_term_current, short_term_prior),
        "lt_total":   (lt_total_current,   lt_total_prior),
        "lt_1yr":     (lt_1yr_current,     lt_1yr_prior),
        "bonds":      (bonds_current,      bonds_prior),
    }



def _is_usgaap_xbrl(tag_elements: dict) -> bool:
    """XBRLインスタンスのタグ群がUS-GAAP企業（連結数値なし）かどうかを判定。"""
    # US-GAAPサマリータグが存在するが、J-GAAP/IFRS の借入金タグが連結値で存在しない
    usgaap_summary_tags = {
        "TotalAssetsUSGAAPSummaryOfBusinessResults",
        "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
        "CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults",
    }
    has_usgaap = any(t in tag_elements for t in usgaap_summary_tags)
    if not has_usgaap:
        return False

    # J-GAAP/IFRS の主要な借入金連結タグが存在しないことを確認
    debt_tags = [
        "ShortTermLoansPayable", "BorrowingsCLIFRS",
        "BondsPayable", "LongTermLoansPayable",
    ]
    for tag in debt_tags:
        c, _ = _find_consolidated_value(tag_elements, tag)
        if c is not None:
            return False
    return True


def _detect_accounting_standard(tag_elements: dict) -> str:
    """会計基準を判定: 'J-GAAP' | 'IFRS' | 'US-GAAP'"""
    if _is_usgaap_xbrl(tag_elements):
        return "US-GAAP"
    ifrs_marker_tags = [
        "InterestBearingLiabilitiesCLIFRS",
        "InterestBearingLiabilitiesNCLIFRS",
        "BorrowingsCLIFRS",
        "BondsPayableNCLIFRS",
        "BorrowingsNCLIFRS",
    ]
    if any(t in tag_elements for t in ifrs_marker_tags):
        return "IFRS"
    return "J-GAAP"


def extract_interest_bearing_debt(xbrl_dir: Path) -> dict:
    """
    XBRLディレクトリから有利子負債を構成要素ごとに抽出する（試験的実装）。

    Returns:
        {
            "current": float | None,      # 合計 当期末（円）
            "prior":   float | None,      # 合計 前期末（円）
            "method":  str,               # "direct" | "computed" | "not_found"
            "components": [               # 各コンポーネント
                {
                    "label": str,         # 日本語ラベル
                    "tag":   str | None,  # 実際にヒットしたタグ名
                    "current": float | None,
                    "prior":   float | None,
                }
            ]
        }
    """
    xml_files = [
        f for f in xbrl_dir.rglob("*.xml")
        if not any(s in f.name for s in ["_lab", "_pre", "_cal", "_def"])
    ]
    xml_files += list(xbrl_dir.rglob("*.xbrl"))

    # 全 XML から数値要素を収集
    tag_elements: dict = {}
    for f in xml_files:
        for tag, ctx_map in _collect_numeric_elements(f).items():
            if tag not in tag_elements:
                tag_elements[tag] = {}
            tag_elements[tag].update(ctx_map)

    accounting_standard = _detect_accounting_standard(tag_elements)

    # --- 直接法 ---
    for ibd_tag in INTEREST_BEARING_DEBT_TAGS:
        current, prior = _find_consolidated_value(tag_elements, ibd_tag)
        if current is None and prior is None:
            current, prior = _find_nonconsolidated_value(tag_elements, ibd_tag)
        if current is not None or prior is not None:
            return {
                "current": current,
                "prior": prior,
                "method": "direct",
                "accounting_standard": accounting_standard,
                "components": [{"label": "有利子負債合計", "tag": ibd_tag,
                                "current": current, "prior": prior}],
            }

    # --- 積み上げ法（コンポーネント別） ---
    # 戦略: 候補タグを順に試し、連結値が見つかった最初のタグを使用。
    #        全候補で連結値がない場合のみ個別値にフォールバック。
    components = []
    for comp_def in COMPONENT_DEFINITIONS:
        found_tag = None
        current = prior = None

        # Phase 1: 連結値を探す
        for tag in comp_def["tags"]:
            c, p = _find_consolidated_value(tag_elements, tag)
            if c is not None or p is not None:
                found_tag = tag
                current, prior = c, p
                break

        # Phase 2: 連結値がなければ個別値にフォールバック
        if found_tag is None:
            for tag in comp_def["tags"]:
                c, p = _find_nonconsolidated_value(tag_elements, tag)
                if c is not None or p is not None:
                    found_tag = tag
                    current, prior = c, p
                    break
        components.append({
            "label": comp_def["label"],
            "tag": found_tag,
            "current": current,
            "prior": prior,
        })

    # --- 集約IFRSタグによる後処理 ---
    # 粒度別タグが存在しない場合に集約タグで置き換え、個別値の混入を防ぐ。
    for agg_def in AGGREGATE_IFRS_DEFINITIONS:
        agg_c, agg_p = _find_consolidated_value(tag_elements, agg_def["tag"])
        if agg_c is None and agg_p is None:
            continue
        # カバー対象のコンポーネントが「連結値なし」かどうか確認
        # （タグ未発見 or 非連結フォールバック のどちらも対象）
        covered = [c for c in components if c["label"] in agg_def["covers"]]
        needs_override = [
            c for c in covered
            if c["tag"] is None  # タグ自体が未発見
            or _find_consolidated_value(tag_elements, c["tag"]) == (None, None)  # 非連結フォールバック
        ]
        if not needs_override:
            continue
        # カバー対象を全てクリア
        for c in covered:
            c["current"] = None
            c["prior"] = None
            c["tag"] = None
        # 最初のカバー対象スロットに集約値を入れる
        first = next(c for c in components if c["label"] == agg_def["covers"][0])
        first["tag"] = agg_def["tag"]
        first["current"] = agg_c
        first["prior"] = agg_p
        first["label"] = agg_def["covers"][0] + "＋" + agg_def["covers"][1] + "（集約）"

    found = [c for c in components if c["current"] is not None or c["prior"] is not None]
    if not found:
        return {"current": None, "prior": None, "method": "not_found", "accounting_standard": accounting_standard, "components": components}

    def safe_sum(vals):
        vs = [v for v in vals if v is not None]
        return sum(vs) if vs else None

    total_current = safe_sum([c["current"] for c in components])
    total_prior = safe_sum([c["prior"] for c in components])

    return {
        "current": total_current,
        "prior": total_prior,
        "method": "computed",
        "accounting_standard": accounting_standard,
        "components": components,
    }


# ---------------------------------------------------------------------------
# テスト（本番実装を使用）
# ---------------------------------------------------------------------------

from blue_ticker.analysis.interest_bearing_debt import (  # noqa: E402
    extract_interest_bearing_debt,
    _extract_ifrs_lease_liabilities,
)
from blue_ticker.analysis.sections import BalanceSheetSection  # noqa: E402

NS_XBRLI = "http://www.xbrl.org/2003/instance"
NS_JPPFS = "http://disclosure.edinet-fsa.go.jp/taxonomy/jppfs/2022-11-01/jppfs_cor"
NS_JPCRP = "http://disclosure.edinet-fsa.go.jp/taxonomy/jpcrp/2022-11-01/jpcrp_cor"


def _make_xbrl(elements_xml: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<xbrli:xbrl
    xmlns:xbrli="{NS_XBRLI}"
    xmlns:jppfs_cor="{NS_JPPFS}"
    xmlns:jpcrp_cor="{NS_JPCRP}">

  <xbrli:context id="CurrentYearInstant">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2024-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="Prior1YearInstant">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2023-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="CurrentYearInstant_NonConsolidatedMember">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2024-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:context id="Prior1YearInstant_NonConsolidatedMember">
    <xbrli:entity>
      <xbrli:identifier scheme="http://disclosure.edinet-fsa.go.jp">E12345</xbrli:identifier>
    </xbrli:entity>
    <xbrli:period><xbrli:instant>2023-03-31</xbrli:instant></xbrli:period>
  </xbrli:context>

  <xbrli:unit id="JPY"><xbrli:measure>iso4217:JPY</xbrli:measure></xbrli:unit>

  {elements_xml}
</xbrli:xbrl>"""


class TestDirectExtraction(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_direct_tag(self):
        xml = _make_xbrl("""
            <jppfs_cor:InterestBearingDebt contextRef="CurrentYearInstant"
                unitRef="JPY">500000000000</jppfs_cor:InterestBearingDebt>
            <jppfs_cor:InterestBearingDebt contextRef="Prior1YearInstant"
                unitRef="JPY">450000000000</jppfs_cor:InterestBearingDebt>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        self.assertAlmostEqual(result["current"], 500_000_000_000)
        self.assertAlmostEqual(result["prior"], 450_000_000_000)


class TestJGaapComponents(unittest.TestCase):
    """J-GAAP タグ（全8コンポーネント）のテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_all_eight_components(self):
        xml = _make_xbrl("""
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">10000000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:CommercialPapersLiabilities contextRef="CurrentYearInstant"
                unitRef="JPY">5000000000</jppfs_cor:CommercialPapersLiabilities>
            <jppfs_cor:CurrentPortionOfBonds contextRef="CurrentYearInstant"
                unitRef="JPY">3000000000</jppfs_cor:CurrentPortionOfBonds>
            <jppfs_cor:CurrentPortionOfLongTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">8000000000</jppfs_cor:CurrentPortionOfLongTermLoansPayable>
            <jppfs_cor:BondsPayable contextRef="CurrentYearInstant"
                unitRef="JPY">50000000000</jppfs_cor:BondsPayable>
            <jppfs_cor:LongTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">30000000000</jppfs_cor:LongTermLoansPayable>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        # 合計: 10+5+3+8+50+30 = 106 十億円
        self.assertAlmostEqual(result["current"], 106_000_000_000)
        labels = [c["label"] for c in result["components"] if c["tag"]]
        self.assertIn("短期借入金", labels)
        self.assertIn("コマーシャル・ペーパー", labels)
        self.assertIn("1年内償還予定の社債", labels)
        self.assertIn("1年内返済予定の長期借入金", labels)
        self.assertIn("社債", labels)
        self.assertIn("長期借入金", labels)


class TestIfrsComponents(unittest.TestCase):
    """IFRS タグのテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_ifrs_tags(self):
        xml = _make_xbrl("""
            <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
            <jppfs_cor:CommercialPapersCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">10000000000</jppfs_cor:CommercialPapersCLIFRS>
            <jppfs_cor:CurrentPortionOfBondsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">24989000000</jppfs_cor:CurrentPortionOfBondsCLIFRS>
            <jppfs_cor:CurrentPortionOfLongTermBorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">8234000000</jppfs_cor:CurrentPortionOfLongTermBorrowingsCLIFRS>
            <jppfs_cor:BondsPayableNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">204412000000</jppfs_cor:BondsPayableNCLIFRS>
            <jppfs_cor:BorrowingsNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">211795000000</jppfs_cor:BorrowingsNCLIFRS>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "IFRS")
        # 合計: 5923+10000+24989+8234+204412+211795 = 465353 百万円
        self.assertAlmostEqual(result["current"], 465_353_000_000)
        tags_found = [c["tag"] for c in result["components"] if c["tag"]]
        self.assertIn("BorrowingsCLIFRS", tags_found)
        self.assertIn("BondsPayableNCLIFRS", tags_found)
        self.assertIn("BorrowingsNCLIFRS", tags_found)

    def test_ifrs_bonds_borrowings_and_lease_liabilities_tags(self):
        """三菱電機形式: 社債、借入金及びリース負債の流動/非流動集約タグを使う。"""
        xml = _make_xbrl("""
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS contextRef="Prior1YearInstant"
                unitRef="JPY">151698000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">120889000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS contextRef="Prior1YearInstant"
                unitRef="JPY">242938000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS>
            <jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">239772000000</jppfs_cor:BondsBorrowingsAndLeaseLiabilitiesNCLIFRS>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "field_parser")
        self.assertEqual(result["accounting_standard"], "IFRS")
        self.assertAlmostEqual(result["current"], 360_661_000_000)
        self.assertAlmostEqual(result["prior"], 394_636_000_000)
        tags_found = [c["tag"] for c in result["components"] if c["tag"]]
        self.assertIn("BondsBorrowingsAndLeaseLiabilitiesCLIFRS", tags_found)
        self.assertIn("BondsBorrowingsAndLeaseLiabilitiesNCLIFRS", tags_found)


class TestConsolidatedPriority(unittest.TestCase):
    """連結が個別より優先されることのテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_consolidated_over_nonconsolidated(self):
        """同タグに連結・個別両方ある場合、連結が使われる。"""
        xml = _make_xbrl("""
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
                unitRef="JPY">999000000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">100000000000</jppfs_cor:ShortTermLoansPayable>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        comp = next(c for c in result["components"] if c["label"] == "短期借入金")
        self.assertAlmostEqual(comp["current"], 999_000_000_000)

    def test_ifrs_tag_preferred_over_jgaap_nonconsolidated(self):
        """IFRS連結タグが J-GAAP 個別タグより優先される。"""
        # 実際のXBRL書類では NetAssets 等のタグが連結・個別両コンテキストに存在し
        # has_nonconsolidated_contexts が True になる。それを再現して非連結フォールバックを抑止する。
        xml = _make_xbrl("""
            <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
                unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
            <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">116294000000</jppfs_cor:ShortTermLoansPayable>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant"
                unitRef="JPY">1000000000000</jppfs_cor:NetAssets>
            <jppfs_cor:NetAssets contextRef="CurrentYearInstant_NonConsolidatedMember"
                unitRef="JPY">800000000000</jppfs_cor:NetAssets>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        comp = next(c for c in result["components"] if c["label"] == "短期借入金")
        # ShortTermLoansPayable は個別のみ → BorrowingsCLIFRS（連結）が選ばれる
        self.assertAlmostEqual(comp["current"], 5_923_000_000)
        self.assertEqual(comp["tag"], "BorrowingsCLIFRS")


class TestNotFound(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_no_debt_tags(self):
        xml = _make_xbrl("""
            <jpcrp_cor:BusinessRisksTextBlock contextRef="CurrentYearInstant">
                テキストのみ
            </jpcrp_cor:BusinessRisksTextBlock>
        """)
        (self.xbrl_dir / "instance.xml").write_text(xml, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["method"], "not_found")
        self.assertIsNone(result["current"])


def _make_xbrl_with_lease_textblock(base_elements_xml: str, lease_html_rows: str) -> str:
    """リース注記TextBlockを含む XBRL を生成する。"""
    lease_html = f"&lt;table&gt;{lease_html_rows}&lt;/table&gt;"
    return _make_xbrl(
        base_elements_xml
        + f"""
    <jpcrp_cor:NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock
        contextRef="CurrentYearInstant">{lease_html}</jpcrp_cor:NotesLeasesConsolidatedFinancialStatementsIFRSTextBlock>
"""
    )


_IFRS_BORROWINGS_XML = """
    <jppfs_cor:BorrowingsCLIFRS contextRef="CurrentYearInstant"
        unitRef="JPY">5923000000</jppfs_cor:BorrowingsCLIFRS>
    <jppfs_cor:BondsPayableNCLIFRS contextRef="CurrentYearInstant"
        unitRef="JPY">204412000000</jppfs_cor:BondsPayableNCLIFRS>
    <jppfs_cor:BorrowingsNCLIFRS contextRef="CurrentYearInstant"
        unitRef="JPY">211795000000</jppfs_cor:BorrowingsNCLIFRS>
"""


class TestExtractIfrsLeaseLiabilities(unittest.TestCase):
    """_extract_ifrs_lease_liabilities のユニットテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_pattern_a_cl_and_ncl(self):
        """パターンA: 流動（1年以内）と非流動（1年超）の両方がある場合。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,500&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
            "&lt;tr&gt;&lt;td&gt;支払期日が1年超&lt;/td&gt;&lt;td&gt;28,000&lt;/td&gt;&lt;td&gt;32,000&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        from blue_ticker.constants.financial import MILLION_YEN
        self.assertAlmostEqual(lease_c, 37_000 * MILLION_YEN)
        self.assertAlmostEqual(lease_p, 32_500 * MILLION_YEN)
        labels = [c["label"] for c in comps]
        self.assertIn("リース負債（流動）", labels)
        self.assertIn("リース負債（非流動）", labels)

    def test_pattern_b_book_value(self):
        """パターンB: 「帳簿価額」行のみある場合。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;帳簿価額&lt;/td&gt;&lt;td&gt;28,500&lt;/td&gt;&lt;td&gt;32,539&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        from blue_ticker.constants.financial import MILLION_YEN
        self.assertAlmostEqual(lease_c, 32_539 * MILLION_YEN)
        self.assertAlmostEqual(lease_p, 28_500 * MILLION_YEN)
        self.assertEqual(len(comps), 1)
        self.assertEqual(comps[0]["label"], "リース負債")

    def test_no_matching_rows_returns_none(self):
        """マッチするリース行がない場合は (None, None, []) を返す。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;減価償却費&lt;/td&gt;&lt;td&gt;1,000&lt;/td&gt;&lt;td&gt;1,200&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        self.assertIsNone(lease_c)
        self.assertIsNone(lease_p)
        self.assertEqual(comps, [])

    def test_no_textblock_returns_none(self):
        """TextBlock自体がない場合は (None, None, []) を返す。"""
        xbrl = _make_xbrl(_IFRS_BORROWINGS_XML)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        section = BalanceSheetSection.from_xbrl(self.xbrl_dir)
        lease_c, lease_p, comps = _extract_ifrs_lease_liabilities(section)
        self.assertIsNone(lease_c)
        self.assertIsNone(lease_p)
        self.assertEqual(comps, [])


class TestIfrsLeaseAddedToIbd(unittest.TestCase):
    """extract_interest_bearing_debt でリース負債が加算されることのテスト。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.xbrl_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_lease_added_to_ifrs_ibd(self):
        """IFRSで借入金タグ + リース注記が両方ある場合、リース負債が加算される。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,000&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
            "&lt;tr&gt;&lt;td&gt;支払期日が1年超&lt;/td&gt;&lt;td&gt;28,000&lt;/td&gt;&lt;td&gt;32,000&lt;/td&gt;&lt;/tr&gt;"
        )
        xbrl = _make_xbrl_with_lease_textblock(_IFRS_BORROWINGS_XML, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        from blue_ticker.constants.financial import MILLION_YEN
        # 借入金合計: 5923+204412+211795 = 422130 百万円
        # リース負債: 5000+32000 = 37000 百万円
        # IBD合計: 459130 百万円
        self.assertIn("lease_textblock", result["method"])
        self.assertAlmostEqual(result["current"], (422_130 + 37_000) * MILLION_YEN)
        labels = [c["label"] for c in result["components"]]
        self.assertIn("リース負債（流動）", labels)
        self.assertIn("リース負債（非流動）", labels)

    def test_jgaap_lease_not_added(self):
        """J-GAAPではリース注記があってもリース負債は加算されない。"""
        rows = (
            "&lt;tr&gt;&lt;td&gt;支払期日が1年以内&lt;/td&gt;&lt;td&gt;4,000&lt;/td&gt;&lt;td&gt;5,000&lt;/td&gt;&lt;/tr&gt;"
        )
        jgaap_xml = """
    <jppfs_cor:ShortTermLoansPayable contextRef="CurrentYearInstant"
        unitRef="JPY">10000000000</jppfs_cor:ShortTermLoansPayable>
    <jppfs_cor:LongTermLoansPayable contextRef="CurrentYearInstant"
        unitRef="JPY">50000000000</jppfs_cor:LongTermLoansPayable>
"""
        xbrl = _make_xbrl_with_lease_textblock(jgaap_xml, rows)
        (self.xbrl_dir / "instance.xml").write_text(xbrl, encoding="utf-8")
        result = extract_interest_bearing_debt(BalanceSheetSection.from_xbrl(self.xbrl_dir))
        self.assertEqual(result["accounting_standard"], "J-GAAP")
        self.assertNotIn("lease_textblock", result["method"])
        self.assertAlmostEqual(result["current"], 60_000_000_000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
