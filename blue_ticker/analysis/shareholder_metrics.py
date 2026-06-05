"""株式・配当・現金同等物 XBRL 抽出モジュール。"""

import html
import re
import xml.etree.ElementTree as ET
from collections.abc import Callable
from pathlib import Path
from typing import cast

from bs4 import BeautifulSoup

from blue_ticker.analysis.xbrl_utils import collect_numeric_elements, find_xbrl_files
from blue_ticker.constants.financial import BPS_PER_SHARE_MIN_VALUE, BPS_SPLIT_ADJUSTMENT_REL_TOLERANCE, MILLION_YEN
from blue_ticker.utils.metrics_types import StockSplitEvent
from blue_ticker.utils.xbrl_result_types import XbrlTagElements

_CASH_EQ_TAGS: list[str] = [
    "CashAndCashEquivalentsIFRS",
    "CashAndCashEquivalents",
    "CashAndCashEquivalentsIFRSSummaryOfBusinessResults",
    "CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults",
    "CashAndCashEquivalentsSummaryOfBusinessResults",
]

_EPS_TAGS: list[str] = [
    "BasicEarningsLossPerShareIFRS",
    "BasicEarningsLossPerShareIFRSSummaryOfBusinessResults",
    "BasicEarningsLossPerShareUSGAAPSummaryOfBusinessResults",
    "BasicEarningsLossPerShareSummaryOfBusinessResults",
]

_BPS_TAGS: list[str] = [
    "EquityAttributableToOwnersOfParentPerShareIFRSSummaryOfBusinessResults",
    "EquityAttributableToOwnersOfParentPerShareUSGAAPSummaryOfBusinessResults",
    # EDINET taxonomy labels this as an equity ratio, but some IFRS filings use it
    # for "1株当たり親会社所有者帰属持分/親会社株主持分" with JPYPerShares.
    "EquityToAssetRatioIFRSSummaryOfBusinessResults",
    "NetAssetsPerShareSummaryOfBusinessResults",
]

_PARENT_EQUITY_TAGS: list[str] = [
    "EquityAttributableToOwnersOfParentIFRS",
    "EquityAttributableToOwnersOfParentIFRSSummaryOfBusinessResults",
    "EquityAttributableToOwnersOfParentUSGAAP",
    "EquityAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults",
]

_AVERAGE_SHARES_TAGS: list[str] = [
    "AverageNumberOfSharesDuringPeriodBasicEarningsLossPerShareInformation",
    "AverageNumberOfSharesDuringTheFiscalYearBasicEarningsLossPerShareInformation",
    "AverageNumberOfShares",
    "WeightedAverageNumberOfSharesOutstandingBasic",
    "WeightedAverageNumberOfOrdinarySharesOutstandingBasicIFRS",
]

_TREASURY_SHARES_TAGS: list[str] = [
    "TotalNumberOfSharesHeldTreasurySharesEtc",
    "NumberOfSharesHeldInOwnNameTreasurySharesEtc",
]

_RATIO_LIKE_BPS_TAGS: frozenset[str] = frozenset(
    {
        "EquityToAssetRatioIFRSSummaryOfBusinessResults",
    }
)

_ISSUED_SHARES_TAGS: list[str] = [
    "NumberOfIssuedSharesAsOfFiscalYearEndIssuedSharesTotalNumberOfSharesEtc",
    "NumberOfIssuedSharesAsOfFilingDateIssuedSharesTotalNumberOfSharesEtc",
    "TotalNumberOfIssuedSharesSummaryOfBusinessResults",
]

_DIVIDEND_PER_SHARE_TAGS: list[str] = [
    "DividendPaidPerShareSummaryOfBusinessResults",
]

_INTERIM_DIVIDEND_PER_SHARE_TAGS: list[str] = [
    "InterimDividendPaidPerShareSummaryOfBusinessResults",
]

_DIVIDEND_TOTAL_TAGS: list[str] = [
    "TotalAmountOfDividendsDividendsOfSurplus",
    "DividendsFromSurplus",
]

_PAYOUT_RATIO_TAGS: list[str] = [
    "PayoutRatioSummaryOfBusinessResults",
]

_SHAREHOLDER_NOTE_TEXTBLOCK_TAGS: frozenset[str] = frozenset(
    {
        "NotesPerShareInformationConsolidatedFinancialStatementsTextBlock",
        "NotesPerShareInformationFinancialStatementsTextBlock",
        "NotesPerShareInformationTextBlock",
        "NotesEarningsPerShareConsolidatedFinancialStatementsIFRSTextBlock",
        "NotesRegardingIssuedSharesAndTreasurySharesTextBlock",
        "IssuedSharesTotalNumberOfSharesEtcTextBlock",
        "TreasurySharesEtcTextBlock",
        "DisposalsOrHoldingOfAcquiredTreasurySharesTextBlock",
        "NotesDividendsConsolidatedFinancialStatementsIFRSTextBlock",
        "DividendsOfSurplusTextBlock",
    }
)

_RELEVANT_TAGS: frozenset[str] = frozenset(
    _CASH_EQ_TAGS
    + _EPS_TAGS
    + _BPS_TAGS
    + _PARENT_EQUITY_TAGS
    + _AVERAGE_SHARES_TAGS
    + _TREASURY_SHARES_TAGS
    + _ISSUED_SHARES_TAGS
    + _DIVIDEND_PER_SHARE_TAGS
    + _INTERIM_DIVIDEND_PER_SHARE_TAGS
    + _DIVIDEND_TOTAL_TAGS
    + _PAYOUT_RATIO_TAGS
)

_CONSOLIDATED_FIRST_CONTEXTS: tuple[str, ...] = (
    "CurrentYearInstant",
    "CurrentYearDuration",
    "InterimInstant",
    "InterimDuration",
    "CurrentYTDDuration",
    "FilingDateInstant",
    "CurrentYearInstant_NonConsolidatedMember",
    "CurrentYearDuration_NonConsolidatedMember",
    "InterimInstant_NonConsolidatedMember",
    "InterimDuration_NonConsolidatedMember",
    "CurrentYTDDuration_NonConsolidatedMember",
    "FilingDateInstant_NonConsolidatedMember",
)

# 配当・発行済株式数・配当性向は、連結財務諸表そのものではなく
# 報告会社/親会社の株式関連情報として開示されることが多い。
# 既存の取得順を維持し、EPS/BPS/CashEq の連結優先順序とは分ける。
_REPORTING_COMPANY_CONTEXTS: tuple[str, ...] = (
    "CurrentYearInstant",
    "CurrentYearInstant_NonConsolidatedMember",
    "CurrentYearDuration",
    "CurrentYearDuration_NonConsolidatedMember",
    "InterimInstant",
    "InterimInstant_NonConsolidatedMember",
    "InterimDuration",
    "InterimDuration_NonConsolidatedMember",
    "CurrentYTDDuration",
    "CurrentYTDDuration_NonConsolidatedMember",
    "FilingDateInstant",
    "FilingDateInstant_NonConsolidatedMember",
)

_NON_CONSOLIDATED_MEMBER = "_NonConsolidatedMember"

# 既知の基底コンテキスト名（セグメント修飾なし）。
# _CONSOLIDATED_FIRST_CONTEXTS と _REPORTING_COMPANY_CONTEXTS の合成集合。
# fallback loop はこのセットへの完全一致のみ許容し、
# FilingDateInstant_ClassAPreferredSharesMember のようなセグメント付き
# コンテキストを誤採用しないようにする。
_KNOWN_PLAIN_CONTEXTS: frozenset[str] = frozenset(
    _CONSOLIDATED_FIRST_CONTEXTS
) | frozenset(_REPORTING_COMPANY_CONTEXTS)

_FULLWIDTH_DIGIT_TRANS = str.maketrans("０１２３４５６７８９．－，", "0123456789.-,")
_NUMBER_RE = re.compile(r"-?\d+(?:,\d{3})*(?:\.\d+)?|-?\d+(?:\.\d+)?")
_SHARE_SPLIT_RE = re.compile(
    r"(?:普通株式)?\s*1株\s*につき\s*([0-9]+(?:\.[0-9]+)?)株"
)
_SHARE_SPLIT_ALT_RE = re.compile(
    r"([0-9]+(?:\.[0-9]+)?)株\s*の割合で株式分割"
)
_JAPANESE_DATE_RE = re.compile(
    r"(?:(20[0-9]{2})年|平成([0-9]+)年|令和([0-9]+)年)\s*"
    r"([0-9]{1,2})月\s*([0-9]{1,2})日"
)
_PARTIAL_EFFECTIVE_DATE_RE = re.compile(
    r"([0-9]{1,2})月\s*([0-9]{1,2})日\s*を効力発生日"
)

MetricSourcePayload = dict[str, str | float | None]
ShareholderMetricValue = (
    float | dict[str, MetricSourcePayload] | list[StockSplitEvent] | None
)
ShareholderMetrics = dict[str, ShareholderMetricValue]
NoteValue = float | list[StockSplitEvent]

_DIRECT_CONFIDENCE = 0.9
_CALCULATED_CONFIDENCE = 0.8
_FALLBACK_CONFIDENCE = 0.65


def _is_non_consolidated_context(context_ref: str) -> bool:
    return _NON_CONSOLIDATED_MEMBER in context_ref


def _local_tag(tag: str) -> str:
    return tag.split("}", 1)[1] if "}" in tag else tag


def _normalize_note_text(text: str) -> str:
    return html.unescape(text).translate(_FULLWIDTH_DIGIT_TRANS).replace("\xa0", " ")


def _note_number(text: str) -> float | None:
    normalized = _normalize_note_text(text).replace("△", "-")
    match = _NUMBER_RE.search(normalized.replace("，", ","))
    if not match:
        return None
    try:
        return float(match.group(0).replace(",", ""))
    except ValueError:
        return None


def _share_unit_scale(text: str) -> float:
    normalized = _normalize_note_text(text)
    if "百万株" in normalized:
        return 1_000_000.0
    if "千株" in normalized:
        return 1_000.0
    return 1.0


def _money_unit_scale(text: str) -> float:
    normalized = _normalize_note_text(text)
    if "兆円" in normalized:
        return 1_000_000_000_000.0
    if "億円" in normalized:
        return 100_000_000.0
    if "百万円" in normalized:
        return MILLION_YEN
    if "千円" in normalized:
        return 1_000.0
    return 1.0


def _current_numeric_from_cells(cells: list[str], scale_text: str) -> float | None:
    values = [
        _note_number(cell)
        for cell in cells[1:]
    ]
    numbers = [value for value in values if value is not None]
    if not numbers:
        return None
    # JPXBRLの注記表は前期、当期の順が多いため、最後の数値を当期値として扱う。
    value = numbers[-1]
    return value * _share_unit_scale(scale_text)


def _current_money_from_cells(cells: list[str], scale_text: str) -> float | None:
    values = [
        _note_number(cell)
        for cell in cells[1:]
    ]
    numbers = [value for value in values if value is not None]
    if not numbers:
        return None
    # JPXBRLの注記表は前期、当期の順が多いため、最後の数値を当期値として扱う。
    value = numbers[-1]
    return value * _money_unit_scale(scale_text)


def _table_rows_from_fragment(fragment: str) -> list[tuple[str, list[str]]]:
    soup = BeautifulSoup(fragment, "html.parser")
    parsed: list[tuple[str, list[str]]] = []
    document_text = soup.get_text(" ", strip=True)
    for table in soup.find_all(lambda tag: _tag_name_endswith(tag, "table")):
        table_text = table.get_text(" ", strip=True)
        for row in table.find_all(lambda tag: _tag_name_endswith(tag, "tr")):
            cells = row.find_all(
                _is_table_cell_tag,
                recursive=False,
            )
            if not cells:
                cells = row.find_all(["td", "th"])
            texts = [cell.get_text(" ", strip=True) for cell in cells]
            if texts:
                parsed.append((f"{document_text} {table_text}", texts))
    return parsed


def _textblock_fragment(element: ET.Element) -> str:
    return _normalize_note_text(ET.tostring(element, encoding="unicode"))


def _plain_text_from_fragment(fragment: str) -> str:
    return BeautifulSoup(fragment, "html.parser").get_text(" ", strip=True)


def _tag_name_endswith(tag: object, suffix: str) -> bool:
    name = getattr(tag, "name", None)
    return isinstance(name, str) and name.endswith(suffix)


def _is_table_cell_tag(tag: object) -> bool:
    name = getattr(tag, "name", None)
    return isinstance(name, str) and name.split(":")[-1] in ("td", "th")


def _extract_split_ratio(text: str) -> float | None:
    match = _SHARE_SPLIT_RE.search(_normalize_note_text(text))
    if not match:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def _japanese_date_to_iso(match: re.Match[str]) -> str | None:
    western_year, heisei_year, reiwa_year, month, day = match.groups()
    if western_year is not None:
        year = int(western_year)
    elif heisei_year is not None:
        year = 1988 + int(heisei_year)
    elif reiwa_year is not None:
        year = 2018 + int(reiwa_year)
    else:
        return None
    return f"{year:04d}-{int(month):02d}-{int(day):02d}"


def _split_event_dates(text: str) -> list[str | None]:
    matches = list(_JAPANESE_DATE_RE.finditer(text))
    if not matches:
        return [None]

    first_date = _japanese_date_to_iso(matches[0])
    fallback_year = int(first_date[:4]) if first_date is not None else None
    effective_dates: list[str] = []
    attached_dates: list[str] = []
    other_dates: list[str] = []
    ignored_dates: list[str] = []
    for match in matches:
        date = _japanese_date_to_iso(match)
        if date is None:
            continue
        tail = text[match.end():match.end() + 24]
        if "基準日" in tail or "開催" in tail:
            ignored_dates.append(date)
        elif "効力発生日" in tail:
            effective_dates.append(date)
        elif "付" in tail[:4]:
            attached_dates.append(date)
        else:
            other_dates.append(date)

    if not effective_dates and fallback_year is not None:
        for match in _PARTIAL_EFFECTIVE_DATE_RE.finditer(text):
            month, day = match.groups()
            effective_dates.append(f"{fallback_year:04d}-{int(month):02d}-{int(day):02d}")

    if effective_dates:
        return list(effective_dates)
    if attached_dates:
        return list(attached_dates)
    candidates: list[str | None] = list(other_dates or ignored_dates)
    return candidates if candidates else [None]


def _split_ratio_matches(text: str) -> list[float]:
    ratios: list[float] = []
    for match in _SHARE_SPLIT_RE.finditer(text):
        try:
            ratios.append(float(match.group(1)))
        except ValueError:
            continue
    if ratios:
        return ratios
    for match in _SHARE_SPLIT_ALT_RE.finditer(text):
        try:
            ratios.append(float(match.group(1)))
        except ValueError:
            continue
    return ratios


def _split_scope(text: str) -> str:
    if "当社" in text:
        return "issuer"
    if any(marker in text for marker in ("同社", "子会社", "保有株式", "投資有価証券")):
        return "other_entity"
    return "issuer"


def _split_already_reflected(text: str) -> bool:
    reflected_markers = (
        "当該株式分割が行われたと仮定",
        "期首に株式分割が行われたと仮定",
        "期首に当該株式分割が行われたと仮定",
        "株式分割後の株数にて算定",
        "株式分割後の株式数にて算定",
    )
    return any(marker in text for marker in reflected_markers)


def _split_applies_to(text: str) -> str:
    applies: list[str] = []
    if any(marker in text for marker in ("1株当たり", "1株あたり", "期中平均")):
        applies.append("per_share_metrics")
    if "配当" in text:
        applies.append("dividends")
    return ",".join(applies) if applies else "unknown"


def _split_dividend_basis(text: str) -> str | None:
    if "配当" not in text:
        return None
    if "分割前" in text and any(marker in text for marker in ("実際", "記載")):
        return "pre_split_actual"
    if "分割後" in text and any(marker in text for marker in ("実際", "記載")):
        return "post_split_actual"
    return None


def _split_context_excerpt(text: str) -> str:
    compact = re.sub(r"\s+", " ", text).strip()
    return compact[:220]


def _split_event_sentences(text: str) -> list[str]:
    normalized = _normalize_note_text(text)
    chunks = re.split(r"(?<=。)|(?<=\.)|\n", normalized)
    return [
        chunk.strip()
        for chunk in chunks
        if "株式分割" in chunk and ("1株につき" in chunk or "割合で株式分割" in chunk)
    ]


def _extract_stock_split_events(text: str) -> list[StockSplitEvent]:
    events: list[StockSplitEvent] = []
    normalized = _normalize_note_text(text)
    for sentence in _split_event_sentences(normalized):
        context_text = f"{sentence} {normalized}"
        ratios = _split_ratio_matches(sentence)
        if not ratios:
            continue
        dates = _split_event_dates(sentence)
        if len(ratios) == 1 and len(dates) > 1:
            ratios = ratios * len(dates)
        if len(dates) == 1 and len(ratios) > 1:
            dates = dates * len(ratios)

        for ratio, effective_date in zip(ratios, dates, strict=False):
            events.append(
                {
                    "ratio": ratio,
                    "effective_date": effective_date,
                    "scope": _split_scope(sentence),
                    "already_reflected": _split_already_reflected(context_text),
                    "applies_to": _split_applies_to(context_text),
                    "dividend_basis": _split_dividend_basis(context_text),
                    "source_statement": "notes",
                    "context_excerpt": _split_context_excerpt(sentence),
                }
            )
    return events


def _issuer_stock_split_events(events: list[StockSplitEvent]) -> list[StockSplitEvent]:
    return [event for event in events if event.get("scope") == "issuer"]


def _dedupe_stock_split_events(events: list[StockSplitEvent]) -> list[StockSplitEvent]:
    deduped: list[StockSplitEvent] = []
    seen: set[tuple[float | None, str | None, str | None]] = set()
    for event in events:
        key = (
            event.get("ratio"),
            event.get("effective_date"),
            event.get("scope"),
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(event)
    return deduped


def _cumulative_split_ratio(events: list[StockSplitEvent]) -> float | None:
    cumulative = 1.0
    seen = False
    for event in _issuer_stock_split_events(events):
        ratio = event.get("ratio")
        if ratio is None or ratio <= 0:
            continue
        cumulative *= ratio
        seen = True
    return cumulative if seen else None


def _apply_note_row_values(
    values: dict[str, NoteValue],
    table_text: str,
    cells: list[str],
) -> None:
    row_text = "".join(cells)
    label = cells[0] if cells else ""
    compact_label = "".join(label.split())

    if (
        "期中平均株式数" in row_text
        or "期中平均普通株式数" in row_text
        or "加重平均株式数" in row_text
    ) and "希薄化" not in row_text:
        value = _current_numeric_from_cells(cells, row_text + table_text)
        if value is not None:
            values["AverageShares"] = value

    if (
        "期末株式数" in row_text
        or "純資産額の算定に用いられた普通株式" in row_text
        or "純資産額の算定上の普通株式" in row_text
    ) and "自己株式" not in compact_label:
        value = _current_numeric_from_cells(cells, row_text + table_text)
        if value is not None:
            values["SharesForBPS"] = value

    if "自己株式" in compact_label and not any(
        marker in compact_label for marker in ("増加", "減少", "取得", "処分", "消却")
    ):
        value = _current_numeric_from_cells(cells, row_text + table_text)
        if value is not None:
            values["TreasuryShares"] = value

    if "1株当たり配当" in row_text or "１株当たり配当" in row_text:
        value = _note_number(row_text)
        row_value = _current_numeric_from_cells(cells, row_text)
        if row_value is not None:
            value = row_value
        if value is not None:
            values["DivAnn"] = value

    if "配当金の総額" in row_text or "配当総額" in row_text:
        value = _current_money_from_cells(cells, row_text + table_text)
        if value is not None:
            values["DivTotalAnn"] = value


def _note_float(values: dict[str, NoteValue], key: str) -> float | None:
    value = values.get(key)
    return value if isinstance(value, float) else None


def _note_split_events(values: dict[str, NoteValue]) -> list[StockSplitEvent]:
    value = values.get("StockSplitEvents")
    if isinstance(value, list):
        return cast(list[StockSplitEvent], value)
    return []


def _apply_note_plain_text_values(values: dict[str, NoteValue], text: str) -> None:
    normalized = _normalize_note_text(_plain_text_from_fragment(text))
    events = _extract_stock_split_events(normalized)
    if events:
        current_events = _note_split_events(values)
        current_events.extend(events)
        current_events = _dedupe_stock_split_events(current_events)
        values["StockSplitEvents"] = current_events
        issuer_events = _issuer_stock_split_events(current_events)
        first_ratio = issuer_events[0].get("ratio") if issuer_events else None
        if first_ratio is not None:
            values["StockSplitRatio"] = first_ratio
        cumulative_ratio = _cumulative_split_ratio(current_events)
        if cumulative_ratio is not None:
            values["CumulativeStockSplitRatio"] = cumulative_ratio
    else:
        split_ratio = _extract_split_ratio(normalized)
        if split_ratio is not None:
            values["StockSplitRatio"] = split_ratio
            values["CumulativeStockSplitRatio"] = split_ratio

    if "自己株式" in normalized and "TreasuryShares" not in values:
        treasury_match = re.search(
            r"自己株式(?:数)?[^0-9]{0,40}([0-9][0-9,]*)\s*(百万株|千株|株)",
            normalized,
        )
        if treasury_match:
            value = _note_number(treasury_match.group(1))
            if value is not None:
                values["TreasuryShares"] = value * _share_unit_scale(treasury_match.group(0))


def _extract_shareholder_note_values(xbrl_dir: Path) -> dict[str, NoteValue]:
    values: dict[str, NoteValue] = {}
    if not (
        any(xbrl_dir.glob("*.xbrl"))
        or any(xbrl_dir.glob("*.xml"))
        or (xbrl_dir / "XBRL").exists()
    ):
        return values
    for xml_file in find_xbrl_files(xbrl_dir):
        try:
            root = ET.parse(xml_file).getroot()
        except ET.ParseError:
            continue
        for elem in root.iter():
            local = _local_tag(elem.tag)
            if local not in _SHAREHOLDER_NOTE_TEXTBLOCK_TAGS:
                continue
            context_ref = elem.attrib.get("contextRef", "")
            if context_ref.startswith("Prior"):
                continue
            fragment = _textblock_fragment(elem)
            _apply_note_plain_text_values(values, fragment)
            for table_text, cells in _table_rows_from_fragment(fragment):
                _apply_note_row_values(values, table_text, cells)
    return values


def _first_current_value(
    tag_elements: XbrlTagElements,
    tags: list[str],
    *,
    context_order: tuple[str, ...],
    include_non_consolidated: bool = True,
    value_filter: Callable[[str, float], bool] | None = None,
) -> float | None:
    for tag in tags:
        ctx_map = tag_elements.get(tag)
        if not ctx_map:
            continue
        for ctx in context_order:
            if (
                ctx in ctx_map
                and (include_non_consolidated or not _is_non_consolidated_context(ctx))
                and (value_filter is None or value_filter(tag, ctx_map[ctx]))
            ):
                return ctx_map[ctx]
        for ctx, value in ctx_map.items():
            if (
                ctx in _KNOWN_PLAIN_CONTEXTS
                and (include_non_consolidated or not _is_non_consolidated_context(ctx))
                and (value_filter is None or value_filter(tag, value))
            ):
                return value
    return None


def _first_consolidated_then_any_current_value(
    tag_elements: XbrlTagElements,
    tags: list[str],
    *,
    value_filter: Callable[[str, float], bool] | None = None,
) -> float | None:
    value = _first_current_value(
        tag_elements,
        tags,
        context_order=_CONSOLIDATED_FIRST_CONTEXTS,
        include_non_consolidated=False,
        value_filter=value_filter,
    )
    if value is not None:
        return value
    return _first_current_value(
        tag_elements,
        tags,
        context_order=_CONSOLIDATED_FIRST_CONTEXTS,
        include_non_consolidated=True,
        value_filter=value_filter,
    )


def _first_reporting_company_current_value(
    tag_elements: XbrlTagElements,
    tags: list[str],
) -> float | None:
    return _first_current_value(
        tag_elements,
        tags,
        context_order=_REPORTING_COMPANY_CONTEXTS,
        include_non_consolidated=True,
    )


def _bps_value_filter(tag: str, value: float) -> bool:
    if tag in _RATIO_LIKE_BPS_TAGS:
        return value > BPS_PER_SHARE_MIN_VALUE
    return True


def _first_bps_value(tag_elements: XbrlTagElements) -> float | None:
    return _first_consolidated_then_any_current_value(
        tag_elements,
        _BPS_TAGS,
        value_filter=_bps_value_filter,
    )


def _first_eps_value(tag_elements: XbrlTagElements) -> float | None:
    return _first_consolidated_then_any_current_value(tag_elements, _EPS_TAGS)


def _sum_filing_rows(tag_elements: XbrlTagElements, tags: list[str]) -> float | None:
    for tag in tags:
        ctx_map = tag_elements.get(tag)
        if not ctx_map:
            continue
        row_values = [
            abs(value)
            for ctx, value in ctx_map.items()
            if ctx.startswith("FilingDateInstant_Row")
        ]
        if row_values:
            return sum(row_values)
        current = _first_reporting_company_current_value(tag_elements, [tag])
        if current is not None:
            return abs(current)
    return None


def _sum_current_rows_or_current(tag_elements: XbrlTagElements, tags: list[str]) -> float | None:
    for tag in tags:
        ctx_map = tag_elements.get(tag)
        if not ctx_map:
            continue
        row_values = [
            abs(value)
            for ctx, value in ctx_map.items()
            if ctx.startswith("CurrentYearInstant_Row")
        ]
        if row_values:
            return sum(row_values)
        current = _first_reporting_company_current_value(tag_elements, [tag])
        if current is not None:
            return abs(current)
    return None


def _calculated_per_share(numerator: float | None, denominator: float | None) -> float | None:
    if numerator is None or denominator is None or denominator <= 0:
        return None
    return numerator / denominator


_BPS_METHOD_DEFAULT = "ParentEquity / SharesForBPS"
_BPS_METHOD_SPLIT_ADJUSTED = "ParentEquity / (SharesForBPS * CumulativeStockSplitRatio)"


def _adjust_bps_for_split(
    calculated_bps: float | None,
    bps: float | None,
    parent_equity: float | None,
    shares_for_bps: float | None,
    split_ratio: float | None,
) -> tuple[float | None, str]:
    # ROE/ROIC等の主指標計算には使われない。
    # 期末後に株式分割が発生した場合、SharesForBPSが分割前株数のままになり
    # CalculatedBPS（検証値）が開示BPSの split_ratio 倍になる問題を補正する。
    # BPSDirectDiff が意味のある値になるよう、CalculatedBPS のみを正規化する。
    if (
        calculated_bps is None
        or bps is None
        or bps <= 0
        or parent_equity is None
        or shares_for_bps is None
        or shares_for_bps <= 0
        or split_ratio is None
        or split_ratio <= 1
    ):
        return calculated_bps, _BPS_METHOD_DEFAULT
    adjusted = parent_equity / (shares_for_bps * split_ratio)
    if abs(adjusted - bps) / bps <= BPS_SPLIT_ADJUSTMENT_REL_TOLERANCE:
        return adjusted, _BPS_METHOD_SPLIT_ADJUSTED
    return calculated_bps, _BPS_METHOD_DEFAULT


def _metric_source(
    source: str,
    statement: str,
    confidence: float,
    *,
    method: str | None = None,
    unit: str | None = None,
) -> MetricSourcePayload:
    payload: MetricSourcePayload = {
        "source": source,
        "statement": statement,
        "confidence": confidence,
    }
    if method is not None:
        payload["method"] = method
    if unit is not None:
        payload["unit"] = unit
    return payload


def _add_source_if_present(
    metric_sources: dict[str, MetricSourcePayload],
    metric: str,
    value: float | None,
    source: str,
    statement: str,
    confidence: float,
    *,
    method: str | None = None,
    unit: str | None = None,
) -> None:
    if value is None:
        return
    metric_sources[metric] = _metric_source(
        source,
        statement,
        confidence,
        method=method,
        unit=unit,
    )


def extract_shareholder_metrics(
    xbrl_dir: Path,
    *,
    pre_parsed: XbrlTagElements | None = None,
    net_profit: float | None = None,
) -> ShareholderMetrics:
    """XBRLから株式・配当・現金同等物を抽出する。

    年次レコードへ載せるため、金額は円単位、1株当たり値は円、
    株式数は株単位で返す。
    """
    if pre_parsed is not None:
        tag_elements: XbrlTagElements = {
            tag: ctx for tag, ctx in pre_parsed.items() if tag in _RELEVANT_TAGS
        }
    else:
        tag_elements = {}
        for f in find_xbrl_files(xbrl_dir):
            for tag, ctx_map in collect_numeric_elements(f, _RELEVANT_TAGS).items():
                if tag not in tag_elements:
                    tag_elements[tag] = {}
                tag_elements[tag].update(ctx_map)

    eps = _first_eps_value(tag_elements)
    div_ann = _first_reporting_company_current_value(
        tag_elements,
        _DIVIDEND_PER_SHARE_TAGS,
    )
    div_total_ann = _sum_filing_rows(tag_elements, _DIVIDEND_TOTAL_TAGS)
    payout_ratio = _first_reporting_company_current_value(tag_elements, _PAYOUT_RATIO_TAGS)
    bps = _first_bps_value(tag_elements)
    average_shares = _first_reporting_company_current_value(
        tag_elements,
        _AVERAGE_SHARES_TAGS,
    )
    issued_shares = _first_reporting_company_current_value(
        tag_elements,
        _ISSUED_SHARES_TAGS,
    )
    treasury_shares = _sum_current_rows_or_current(tag_elements, _TREASURY_SHARES_TAGS)
    shares_for_bps = (
        issued_shares - treasury_shares
        if issued_shares is not None and treasury_shares is not None
        else None
    )
    if shares_for_bps is not None and shares_for_bps <= 0:
        shares_for_bps = None
    parent_equity = _first_consolidated_then_any_current_value(
        tag_elements,
        _PARENT_EQUITY_TAGS,
    )

    note_values = _extract_shareholder_note_values(xbrl_dir)
    note_div_ann = _note_float(note_values, "DivAnn")
    note_div_total_ann = _note_float(note_values, "DivTotalAnn")
    note_average_shares = _note_float(note_values, "AverageShares")
    note_treasury_shares = _note_float(note_values, "TreasuryShares")
    note_shares_for_bps = _note_float(note_values, "SharesForBPS")
    stock_split_ratio = _note_float(note_values, "StockSplitRatio")
    cumulative_stock_split_ratio = _note_float(note_values, "CumulativeStockSplitRatio")
    stock_split_events = _note_split_events(note_values)

    div_ann_from_notes = div_ann is None and note_div_ann is not None
    div_total_ann_from_notes = div_total_ann is None and note_div_total_ann is not None
    average_shares_from_notes = (
        average_shares is None and note_average_shares is not None
    )
    treasury_shares_from_notes = (
        treasury_shares is None and note_treasury_shares is not None
    )
    shares_for_bps_from_notes = (
        shares_for_bps is None and note_shares_for_bps is not None
    )
    if div_ann_from_notes:
        div_ann = note_div_ann
    if div_total_ann_from_notes:
        div_total_ann = note_div_total_ann
    if average_shares_from_notes:
        average_shares = note_average_shares
    if treasury_shares_from_notes:
        treasury_shares = note_treasury_shares
    if shares_for_bps_from_notes:
        shares_for_bps = note_shares_for_bps
    if shares_for_bps is None and issued_shares is not None and treasury_shares is not None:
        shares_for_bps = issued_shares - treasury_shares
    if shares_for_bps is not None and shares_for_bps <= 0:
        shares_for_bps = None
    payout_ratio_from_calculation = False
    if payout_ratio is None and div_ann is not None and eps is not None and eps != 0:
        payout_ratio = round(div_ann / eps, 3)
        payout_ratio_from_calculation = True

    calculated_eps = _calculated_per_share(net_profit, average_shares)
    calculated_bps, calculated_bps_method = _adjust_bps_for_split(
        _calculated_per_share(parent_equity, shares_for_bps),
        bps,
        parent_equity,
        shares_for_bps,
        cumulative_stock_split_ratio,
    )
    eps_direct_diff = (
        eps - calculated_eps if eps is not None and calculated_eps is not None else None
    )
    bps_direct_diff = (
        bps - calculated_bps if bps is not None and calculated_bps is not None else None
    )
    cash_eq = _first_consolidated_then_any_current_value(tag_elements, _CASH_EQ_TAGS)

    metric_sources: dict[str, MetricSourcePayload] = {}
    _add_source_if_present(
        metric_sources,
        "CashEq",
        cash_eq,
        "direct",
        "consolidated",
        _DIRECT_CONFIDENCE,
        unit="yen",
    )
    _add_source_if_present(
        metric_sources,
        "EPS",
        eps,
        "direct",
        "summary",
        _DIRECT_CONFIDENCE,
        method="direct",
        unit="yen_per_share",
    )
    _add_source_if_present(
        metric_sources,
        "BPS",
        bps,
        "direct",
        "summary",
        _DIRECT_CONFIDENCE,
        method="direct",
        unit="yen_per_share",
    )
    _add_source_if_present(
        metric_sources,
        "ShOutFY",
        issued_shares,
        "direct",
        "summary",
        _DIRECT_CONFIDENCE,
        unit="shares",
    )
    _add_source_if_present(
        metric_sources,
        "AverageShares",
        average_shares,
        "fallback" if average_shares_from_notes else "direct",
        "notes" if average_shares_from_notes else "summary",
        _FALLBACK_CONFIDENCE if average_shares_from_notes else _DIRECT_CONFIDENCE,
        method="textblock_table" if average_shares_from_notes else None,
        unit="shares",
    )
    _add_source_if_present(
        metric_sources,
        "TreasuryShares",
        treasury_shares,
        "fallback" if treasury_shares_from_notes else "direct",
        "notes" if treasury_shares_from_notes else "summary",
        _FALLBACK_CONFIDENCE if treasury_shares_from_notes else _DIRECT_CONFIDENCE,
        method="textblock_table" if treasury_shares_from_notes else None,
        unit="shares",
    )
    _add_source_if_present(
        metric_sources,
        "SharesForBPS",
        shares_for_bps,
        "fallback" if shares_for_bps_from_notes else "calculated",
        "notes" if shares_for_bps_from_notes else "summary",
        _FALLBACK_CONFIDENCE if shares_for_bps_from_notes else _CALCULATED_CONFIDENCE,
        method="textblock_table" if shares_for_bps_from_notes else "ShOutFY - TreasuryShares",
        unit="shares",
    )
    _add_source_if_present(
        metric_sources,
        "ParentEquity",
        parent_equity,
        "direct",
        "consolidated",
        _DIRECT_CONFIDENCE,
        unit="yen",
    )
    _add_source_if_present(
        metric_sources,
        "StockSplitRatio",
        stock_split_ratio,
        "fallback",
        "notes",
        _FALLBACK_CONFIDENCE,
        method="textblock",
    )
    _add_source_if_present(
        metric_sources,
        "CumulativeStockSplitRatio",
        cumulative_stock_split_ratio,
        "fallback",
        "notes",
        _FALLBACK_CONFIDENCE,
        method="textblock_events",
    )
    if stock_split_events:
        metric_sources["StockSplitEvents"] = _metric_source(
            "fallback",
            "notes",
            _FALLBACK_CONFIDENCE,
            method="textblock_events",
        )
    _add_source_if_present(
        metric_sources,
        "CalculatedEPS",
        calculated_eps,
        "calculated",
        "consolidated",
        _CALCULATED_CONFIDENCE,
        method="NP / AverageShares",
        unit="yen_per_share",
    )
    _add_source_if_present(
        metric_sources,
        "CalculatedBPS",
        calculated_bps,
        "calculated",
        "consolidated",
        _CALCULATED_CONFIDENCE,
        method=calculated_bps_method,
        unit="yen_per_share",
    )
    _add_source_if_present(
        metric_sources,
        "EPSDirectDiff",
        eps_direct_diff,
        "calculated",
        "summary",
        _DIRECT_CONFIDENCE,
        method="EPS - CalculatedEPS",
        unit="yen_per_share",
    )
    _add_source_if_present(
        metric_sources,
        "BPSDirectDiff",
        bps_direct_diff,
        "calculated",
        "summary",
        _DIRECT_CONFIDENCE,
        method="BPS - CalculatedBPS",
        unit="yen_per_share",
    )
    _add_source_if_present(
        metric_sources,
        "DivAnn",
        div_ann,
        "fallback" if div_ann_from_notes else "direct",
        "notes" if div_ann_from_notes else "summary",
        _FALLBACK_CONFIDENCE if div_ann_from_notes else _DIRECT_CONFIDENCE,
        method="textblock_table" if div_ann_from_notes else None,
        unit="yen_per_share",
    )
    _add_source_if_present(
        metric_sources,
        "DivTotalAnn",
        div_total_ann,
        "fallback" if div_total_ann_from_notes else "direct",
        "notes" if div_total_ann_from_notes else "summary",
        _FALLBACK_CONFIDENCE if div_total_ann_from_notes else _DIRECT_CONFIDENCE,
        method="textblock_table" if div_total_ann_from_notes else None,
        unit="yen",
    )
    _add_source_if_present(
        metric_sources,
        "PayoutRatioAnn",
        payout_ratio,
        "calculated" if payout_ratio_from_calculation else "direct",
        "notes" if payout_ratio_from_calculation and div_ann_from_notes else "summary",
        _CALCULATED_CONFIDENCE if payout_ratio_from_calculation else _DIRECT_CONFIDENCE,
        method="DivAnn / EPS" if payout_ratio_from_calculation else None,
        unit="ratio",
    )

    return {
        "CashEq": cash_eq,
        "EPS": eps,
        "BPS": bps,
        "ShOutFY": issued_shares,
        "AverageShares": average_shares,
        "TreasuryShares": treasury_shares,
        "SharesForBPS": shares_for_bps,
        "ParentEquity": parent_equity,
        "StockSplitRatio": stock_split_ratio,
        "CumulativeStockSplitRatio": cumulative_stock_split_ratio,
        "StockSplitEvents": stock_split_events,
        "CalculatedEPS": calculated_eps,
        "CalculatedBPS": calculated_bps,
        "EPSDirectDiff": eps_direct_diff,
        "BPSDirectDiff": bps_direct_diff,
        "DivAnn": div_ann,
        "Div2Q": _first_reporting_company_current_value(
            tag_elements,
            _INTERIM_DIVIDEND_PER_SHARE_TAGS,
        ),
        "DivTotalAnn": div_total_ann,
        "PayoutRatioAnn": payout_ratio,
        "MetricSources": metric_sources,
    }
