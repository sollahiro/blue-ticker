"""
EDINET書類発見ユーティリティ

build_document_index_for_code() が主エントリーポイント。

処理フロー:
  ① 直近 initial_scan_days 日をスキャンして最新の有価証券報告書を発見
     （periodEnd から会計期末パターンを確定）
  ② 各過去年度を3段階フォールバックで検索（前年提出日を活用）
     Tier 1: 前年の提出日 ± 2週間（高速）
     Tier 2: 期末+60日 前後1ヶ月（合計2ヶ月窓）
     Tier 3: [期末日, 期末日+185日]（提出期限延長申請の法的上限 6ヶ月）
  ③ 直近スキャン範囲から訂正有価証券報告書（130）を parentDocID で突合して追加

書類のフィールド付与:
  edinet_fy_end  : 会計期末日 (YYYY-MM-DD)
  fiscal_year     : 期首年（開始年）
  period_type     : "FY" 固定
  _is_amendment   : 訂正書類のみ True
"""

import asyncio
import calendar
import logging
from datetime import date, datetime, timedelta
from typing import TYPE_CHECKING, Any

from .fiscal_year import format_document_date, parse_date_string

if TYPE_CHECKING:
    from ..api.edinet_client import EdinetAPIClient

logger = logging.getLogger(__name__)

_ANNUAL_REPORT_DOC_TYPE = "120"
_AMENDMENT_DOC_TYPE = "130"
_HALF_YEAR_REPORT_DOC_TYPES = frozenset({"140", "160"})
_BATCH_SIZE = 10
_TIER1_WINDOW_DAYS = 14
_TIER2_OFFSET_DAYS = 60   # 期末からの期待提出オフセット
_TIER2_MARGIN_DAYS = 30   # 期待提出日前後の余裕
_TIER3_MAX_DAYS = 185     # 提出期限延長申請の法的上限（6ヶ月）に合わせた上限


def _safe_fy_end_date(month: int, day: int, year: int, *, use_last_day: bool = False) -> date:
    """月末日を安全に処理しつつ会計期末日を構築する。

    use_last_day=True のとき、day を無視してその月の末日を返す。
    最新期末が月末日（2月末など）の場合に過去年度でも月末を使うために用いる。
    """
    last_day = calendar.monthrange(year, month)[1]
    if use_last_day:
        return date(year, month, last_day)
    return date(year, month, min(day, last_day))


def _add_months_safe(value: date, months: int) -> date:
    """月末日を安全に処理しつつ月数を加算する。"""
    month_index = value.month - 1 + months
    year = value.year + month_index // 12
    month = month_index % 12 + 1
    last_day = calendar.monthrange(year, month)[1]
    return date(year, month, min(value.day, last_day))


def _add_year_safe(value: date, years: int) -> date:
    """うるう日を安全に処理しつつ年数を加算する。"""
    try:
        return value.replace(year=value.year + years)
    except ValueError:
        return value.replace(year=value.year + years, day=28)


async def _fetch_date_range_cached(
    edinet_client: "EdinetAPIClient",
    start: date,
    end: date,
) -> dict[str, list[dict[str, Any]]]:
    """start〜end（含む）の各日付の /documents.json を並列取得して返す。

    EdinetCacheStore のキャッシュが利用されるため、他銘柄で取得済みの日付は無料。
    """
    from blue_ticker.api.edinet_client import EdinetAPIClient

    if isinstance(edinet_client, EdinetAPIClient):
        return await edinet_client.get_documents_for_date_range(start, end)

    dates: list[str] = []
    curr = start
    while curr <= end:
        dates.append(curr.strftime("%Y-%m-%d"))
        curr += timedelta(days=1)

    result: dict[str, list[dict[str, Any]]] = {}
    for i in range(0, len(dates), _BATCH_SIZE):
        batch = dates[i: i + _BATCH_SIZE]
        responses = await asyncio.gather(
            *[edinet_client._get_documents_for_date(d) for d in batch],
            return_exceptions=True,
        )
        for d, res in zip(batch, responses):
            docs_for_date: list[dict[str, Any]]
            if isinstance(res, BaseException):
                docs_for_date = []
            else:
                docs_for_date = res
            result[d] = docs_for_date
    return result


async def _find_most_recent_annual_report(
    code: str,
    edinet_client: "EdinetAPIClient",
    scan_days: int,
) -> dict[str, Any] | None:
    """EDINET を直近 scan_days 日スキャンして最新の有価証券報告書（120）を返す。

    periodEnd が設定されていないものは除外する（訂正書類等）。
    日付ごとのレスポンスはキャッシュを利用するため、2回目以降は高速。
    """
    code_4digit = code[:4] if len(code) >= 4 else code
    today = datetime.now().date()
    scan_start = today - timedelta(days=scan_days - 1)
    docs_by_date = await _fetch_date_range_cached(edinet_client, scan_start, today)

    for date_str in sorted(docs_by_date.keys(), reverse=True):
        for doc in docs_by_date[date_str]:
            sec = str(doc.get("secCode", "")).strip()
            if not sec.startswith(code_4digit):
                continue
            if doc.get("docTypeCode") != _ANNUAL_REPORT_DOC_TYPE:
                continue
            if not doc.get("periodEnd"):
                continue
            logger.info(
                f"[EDINET Discovery] {code}: 直近有報発見 "
                f"periodEnd={doc.get('periodEnd')} "
                f"submit={format_document_date(doc.get('submitDateTime'))}"
            )
            return doc

    logger.warning(
        f"[EDINET Discovery] {code}: {scan_days}日間スキャンで有価証券報告書が見つかりませんでした"
    )
    return None


async def _find_annual_report_for_fy(
    code: str,
    fy_end: date,
    edinet_client: "EdinetAPIClient",
    *,
    prev_submit_date: date | None,
) -> dict[str, Any] | None:
    """指定した会計期末日の有価証券報告書（120）を3段階フォールバックで検索する。

    Tier 1: 前年の提出日 ± 2週間
    Tier 2: 期末+60日 前後1ヶ月（合計2ヶ月窓）
    Tier 3: 期末日〜期末日+97日（法定上限）

    periodEnd の完全一致で絞るため、会計期末が一致しない書類はヒットしない。
    """
    code_4digit = code[:4] if len(code) >= 4 else code
    fy_end_str = fy_end.strftime("%Y-%m-%d")
    today = datetime.now().date()

    async def _search(start: date, end: date) -> dict[str, Any] | None:
        actual_end = min(end, today)
        if start > actual_end:
            return None
        docs_by_date = await _fetch_date_range_cached(edinet_client, start, actual_end)
        for date_str in sorted(docs_by_date.keys(), reverse=True):
            for doc in docs_by_date[date_str]:
                if not str(doc.get("secCode", "")).strip().startswith(code_4digit):
                    continue
                if doc.get("docTypeCode") != _ANNUAL_REPORT_DOC_TYPE:
                    continue
                if doc.get("periodEnd") != fy_end_str:
                    continue
                return doc
        return None

    # Tier 1: 前年提出日 ± 2週間
    if prev_submit_date is not None:
        found = await _search(
            prev_submit_date - timedelta(days=_TIER1_WINDOW_DAYS),
            prev_submit_date + timedelta(days=_TIER1_WINDOW_DAYS),
        )
        if found:
            logger.info(f"[EDINET Discovery] {code} {fy_end_str}: Tier1 hit")
            return found

    # Tier 2: 期末+60日 前後1ヶ月（2ヶ月窓）
    expected = fy_end + timedelta(days=_TIER2_OFFSET_DAYS)
    found = await _search(
        expected - timedelta(days=_TIER2_MARGIN_DAYS),
        expected + timedelta(days=_TIER2_MARGIN_DAYS),
    )
    if found:
        logger.info(f"[EDINET Discovery] {code} {fy_end_str}: Tier2 hit")
        return found

    # Tier 3: 法定上限 [期末日, 期末日+97日]
    found = await _search(fy_end, fy_end + timedelta(days=_TIER3_MAX_DAYS))
    if found:
        logger.info(f"[EDINET Discovery] {code} {fy_end_str}: Tier3 hit")
        return found

    logger.warning(f"[EDINET Discovery] {code} {fy_end_str}: 3段階フォールバックで見つかりませんでした")
    return None


async def _find_amendments(
    original_doc_ids: set[str],
    edinet_client: "EdinetAPIClient",
    search_start: date,
    search_end: date,
) -> list[dict[str, Any]]:
    """parentDocID で突合して訂正有価証券報告書（130）を収集する。

    search_start〜search_end: スキャン範囲。
    build_document_index_for_code から呼ぶ際は既キャッシュ範囲を渡すと無料。
    """
    if not original_doc_ids:
        return []

    docs_by_date = await _fetch_date_range_cached(edinet_client, search_start, search_end)
    amendments: list[dict[str, Any]] = []

    for date_str in sorted(docs_by_date.keys()):
        for doc in docs_by_date[date_str]:
            if doc.get("docTypeCode") != _AMENDMENT_DOC_TYPE:
                continue
            parent_id = doc.get("parentDocID")
            if parent_id and parent_id in original_doc_ids:
                amendments.append(doc)
                logger.info(
                    f"[EDINET Discovery] 訂正書類: docID={doc.get('docID')} "
                    f"parentDocID={parent_id}"
                )

    return amendments


def _attach_fy_metadata(
    doc: dict[str, Any],
    fy_end_str: str,
    fiscal_year: int,
) -> None:
    """書類に edinet_fy_end / fiscal_year / period_type を付与する（in-place）。"""
    doc["edinet_fy_end"] = fy_end_str
    doc["fiscal_year"] = fiscal_year
    doc["period_type"] = "FY"


def _attach_half_metadata(
    doc: dict[str, Any],
    *,
    fy_end_str: str,
    fiscal_year: int,
    period_start: date,
    half_end: date,
) -> None:
    """半期書類にEDINET由来の年度メタ情報を付与する（in-place）。"""
    doc["edinet_fy_end"] = fy_end_str
    doc["fiscal_year"] = fiscal_year
    doc["period_type"] = "2Q"
    doc["edinet_period_start"] = period_start.strftime("%Y-%m-%d")
    doc["edinet_period_end"] = half_end.strftime("%Y-%m-%d")


async def _find_half_report_for_fy(
    code: str,
    period_start: date,
    fy_end: date,
    edinet_client: "EdinetAPIClient",
) -> dict[str, Any] | None:
    """指定年度の半期報告書（160）または旧2Q四半期報告書（140）を検索する。"""
    code_4digit = code[:4] if len(code) >= 4 else code
    half_end = _add_months_safe(period_start, 6) - timedelta(days=1)
    fy_end_str = fy_end.strftime("%Y-%m-%d")
    half_end_str = half_end.strftime("%Y-%m-%d")
    period_start_str = period_start.strftime("%Y-%m-%d")
    today = datetime.now().date()
    search_start = half_end + timedelta(days=1)
    search_end = min(half_end + timedelta(days=90), today)
    if search_start > search_end:
        return None

    docs_by_date = await _fetch_date_range_cached(edinet_client, search_start, search_end)
    candidates: list[dict[str, Any]] = []
    for date_str in sorted(docs_by_date.keys(), reverse=True):
        for doc in docs_by_date[date_str]:
            if not str(doc.get("secCode", "")).strip().startswith(code_4digit):
                continue
            doc_type = doc.get("docTypeCode")
            if doc_type not in _HALF_YEAR_REPORT_DOC_TYPES:
                continue
            desc = str(doc.get("docDescription") or "")
            if "訂正" in desc or "補正" in desc:
                continue

            doc_period_end = str(doc.get("periodEnd") or "")
            doc_period_start = str(doc.get("periodStart") or "")
            if doc_type == "160":
                # 半期報告書の一覧メタデータは periodEnd に通期の期末を持つ。
                if doc_period_end and doc_period_end != fy_end_str:
                    continue
                if doc_period_start and doc_period_start != period_start_str:
                    continue
            else:
                # 旧2Q四半期報告書は periodEnd が2Q末、periodStart は第2四半期開始日。
                if doc_period_end and doc_period_end != half_end_str:
                    continue
                if "第2四半期" not in desc:
                    continue
            candidates.append(doc)

    if not candidates:
        logger.warning(f"[EDINET Discovery] {code} {fy_end_str}: 半期書類が見つかりませんでした")
        return None

    found = sorted(candidates, key=lambda d: str(d.get("submitDateTime") or ""), reverse=True)[0]
    _attach_half_metadata(
        found,
        fy_end_str=fy_end_str,
        fiscal_year=period_start.year,
        period_start=period_start,
        half_end=half_end,
    )
    logger.info(
        f"[EDINET Discovery] {code} {fy_end_str}: 半期書類 hit "
        f"periodEnd={half_end_str} docType={found.get('docTypeCode')}"
    )
    return found


async def build_document_index_for_code(
    code: str,
    edinet_client: "EdinetAPIClient",
    *,
    initial_scan_days: int = 365,
    analysis_years: int = 5,
    known_not_found_fy_ends: frozenset[str] = frozenset(),
) -> tuple[list[dict[str, Any]], list[str]]:
    """EDINETで指定銘柄の過去 analysis_years 年分の有価証券報告書を発見する。

    返却リストには通常書類（docTypeCode=120）と訂正書類（130）が含まれる。
    各書類には edinet_fy_end / fiscal_year / period_type が付与されており、
    EdinetFetcher がそのまま利用できる形式。
    訂正書類には _is_amendment=True が付与される。

    Args:
        code: 銘柄コード（4桁または5桁）
        edinet_client: EdinetAPIClient インスタンス
        initial_scan_days: 直近スキャン日数（デフォルト365日）
        analysis_years: 取得する年数（デフォルト5）
        known_not_found_fy_ends: 前回検索で見つからなかった期末日（YYYY-MM-DD）。
            検索窓が完全に過去の年度のみ格納されている前提。

    Returns:
        (docs, not_found_fy_ends) のタプル。
        docs: 書類リスト（新しい年度順、末尾に訂正書類）。見つからない場合は空リスト。
        not_found_fy_ends: 今回新たに「検索窓が過去になっても見つからなかった」年度の
            期末日リスト（YYYY-MM-DD）。
    """
    # ① 直近スキャンで最新有報を発見
    recent = await _find_most_recent_annual_report(code, edinet_client, initial_scan_days)
    if not recent:
        return [], []

    # periodEnd から会計期末パターンを確定
    period_end_str: str = recent.get("periodEnd", "")
    period_end_dt = parse_date_string(period_end_str)
    if not period_end_dt:
        logger.warning(
            f"[EDINET Discovery] {code}: periodEnd を解析できません: {period_end_str!r}"
        )
        return [], []

    fy_end_month = period_end_dt.month
    fy_end_day = period_end_dt.day
    # 最新期末が月末日（2月末など）なら過去年度も月末日で検索する（うるう年対応）
    fy_end_is_month_end = (fy_end_day == calendar.monthrange(period_end_dt.year, fy_end_month)[1])

    # fiscal_year は periodStart の年（期首年）
    period_start_dt = parse_date_string(recent.get("periodStart", ""))
    fiscal_year_recent = period_start_dt.year if period_start_dt else period_end_dt.year - 1

    _attach_fy_metadata(recent, period_end_str, fiscal_year_recent)
    docs: list[dict[str, Any]] = [recent]

    # 前年提出日（Tier1 の基点）
    prev_submit_date: date | None = None
    submit_str = format_document_date(recent.get("submitDateTime"))
    if submit_str:
        dt = parse_date_string(submit_str)
        if dt:
            prev_submit_date = dt.date()

    today = datetime.now().date()
    not_found_fy_ends: list[str] = []

    # ② 過去年度を3段階フォールバックで検索
    for i in range(1, analysis_years + 1):
        target_year = period_end_dt.year - i
        fy_end = _safe_fy_end_date(fy_end_month, fy_end_day, target_year, use_last_day=fy_end_is_month_end)
        fy_end_str_i = fy_end.strftime("%Y-%m-%d")

        # 前年提出日を1年前にシフトして Tier1 の初期値とする
        expected_prev: date | None = None
        if prev_submit_date is not None:
            try:
                expected_prev = prev_submit_date.replace(year=prev_submit_date.year - 1)
            except ValueError:
                expected_prev = prev_submit_date - timedelta(days=365)

        if fy_end_str_i in known_not_found_fy_ends:
            logger.debug(f"[EDINET Discovery] {code} {fy_end_str_i}: negative cache skip")
            prev_submit_date = expected_prev
            continue

        found = await _find_annual_report_for_fy(
            code, fy_end, edinet_client, prev_submit_date=expected_prev
        )

        if found:
            ps_dt = parse_date_string(found.get("periodStart", ""))
            fy_i = ps_dt.year if ps_dt else fy_end.year - 1
            _attach_fy_metadata(found, fy_end_str_i, fy_i)
            docs.append(found)
            s = format_document_date(found.get("submitDateTime"))
            dt2 = parse_date_string(s)
            prev_submit_date = dt2.date() if dt2 else expected_prev
        else:
            # 見つからなくても継続（途中欠損を許容し、提出日推定を1年ずらす）
            prev_submit_date = expected_prev
            # 提出期限（期末+TIER3_MAX_DAYS）が完全に過去になった年度だけ negative cache する
            if (fy_end + timedelta(days=_TIER3_MAX_DAYS)) < today:
                not_found_fy_ends.append(fy_end_str_i)

    # ③ 訂正書類の収集（直近 initial_scan_days 日 = 既キャッシュ範囲）
    amendments_start = today - timedelta(days=initial_scan_days)
    original_ids = {d["docID"] for d in docs if d.get("docID")}
    amendments = await _find_amendments(original_ids, edinet_client, amendments_start, today)

    # 訂正書類に parentDocID → edinet_fy_end / fiscal_year を付与
    fy_meta_by_doc_id: dict[str, tuple[str, int | None]] = {
        d["docID"]: (d.get("edinet_fy_end", ""), d.get("fiscal_year"))
        for d in docs
        if d.get("docID")
    }
    for amendment in amendments:
        parent_id: str = amendment.get("parentDocID", "")
        if parent_id in fy_meta_by_doc_id:
            fy_end_str_a, fy_a = fy_meta_by_doc_id[parent_id]
            amendment["edinet_fy_end"] = fy_end_str_a
            amendment["fiscal_year"] = fy_a
            amendment["period_type"] = "FY"
        amendment["_is_amendment"] = True

    docs.extend(amendments)

    n_annual = sum(1 for d in docs if d.get("docTypeCode") == _ANNUAL_REPORT_DOC_TYPE)
    n_amend = sum(1 for d in docs if d.get("docTypeCode") == _AMENDMENT_DOC_TYPE)
    logger.info(f"[EDINET Discovery] {code}: 有報{n_annual}件 訂正{n_amend}件 発見")
    return docs, not_found_fy_ends


async def build_half_year_document_index_for_code(
    code: str,
    edinet_client: "EdinetAPIClient",
    *,
    initial_scan_days: int = 365,
    analysis_years: int = 5,
) -> list[dict[str, Any]]:
    """EDINETで指定銘柄の半期/2Q報告書を発見する。

    最新有報から決算期パターンを確定し、各年度の期首から半期末を推定して
    EDINET 日次一覧（キャッシュ対応）から docTypeCode=160/140 を検索する。
    返却書類には edinet_fy_end / period_type="2Q" など、既存 fetcher が扱える
    メタ情報を付与する。
    """
    _all_docs, _ = await build_document_index_for_code(
        code,
        edinet_client,
        initial_scan_days=initial_scan_days,
        analysis_years=analysis_years,
    )
    annual_docs = [
        doc for doc in _all_docs
        if doc.get("docTypeCode") == _ANNUAL_REPORT_DOC_TYPE and not doc.get("_is_amendment")
    ]
    if not annual_docs:
        return []

    fy_periods: dict[str, tuple[date, date]] = {}
    for doc in annual_docs:
        fy_end_dt = parse_date_string(str(doc.get("edinet_fy_end") or doc.get("periodEnd") or ""))
        fy_start_dt = parse_date_string(str(doc.get("periodStart") or ""))
        if not fy_end_dt or not fy_start_dt:
            continue
        fy_periods[fy_end_dt.strftime("%Y-%m-%d")] = (fy_start_dt.date(), fy_end_dt.date())

    if fy_periods:
        newest_fy_end = max(fy_periods.keys())
        start, end = fy_periods[newest_fy_end]
        next_start = end + timedelta(days=1)
        next_end = _add_year_safe(end, 1)
        fy_periods[next_end.strftime("%Y-%m-%d")] = (next_start, next_end)

    docs: list[dict[str, Any]] = []
    for fy_end_str in sorted(fy_periods.keys(), reverse=True):
        if len(docs) >= analysis_years:
            break
        period_start, fy_end = fy_periods[fy_end_str]
        found = await _find_half_report_for_fy(code, period_start, fy_end, edinet_client)
        if found is not None:
            docs.append(found)

    logger.info(f"[EDINET Discovery] {code}: 半期書類{len(docs)}件 発見")
    return docs
