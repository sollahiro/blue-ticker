"""
EDINET書類発見ユーティリティ

build_document_index_for_code() が主エントリーポイント。

処理フロー:
  ① 直近 initial_scan_days 日をスキャンして最新の有価証券報告書を発見
     → edinetCode を取得
  ② 必要年数分の年次インデックス（EdinetAPIClient.ensure_document_index_for_year）を
     並列取得し、edinetCode でフィルタして全有報を収集
     → 決算期変更・商号変更にかかわらず全履歴を取得できる
  ③ edinetCode が一致する訂正有価証券報告書（130）を parentDocID で突合して追加

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
            if isinstance(res, BaseException) or res is None:
                docs_for_date = []
            else:
                docs_for_date = res
            result[d] = docs_for_date
    return result


_SEED_DOC_TYPES = frozenset({_ANNUAL_REPORT_DOC_TYPE}) | _HALF_YEAR_REPORT_DOC_TYPES


async def _find_most_recent_filing(
    code: str,
    edinet_client: "EdinetAPIClient",
    scan_days: int,
) -> dict[str, Any] | None:
    """EDINET を直近 scan_days 日スキャンして edinetCode 取得用の書類を1件返す。

    有価証券報告書（120）・半期報告書（160）・四半期報告書（140）のいずれかを返す。
    どの書類型でも edinetCode は共通のため、年次インデックス探索の起点として十分。
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
            if doc.get("docTypeCode") not in _SEED_DOC_TYPES:
                continue
            if not doc.get("edinetCode"):
                continue
            logger.info(
                f"[EDINET Discovery] {code}: 直近書類発見 "
                f"docType={doc.get('docTypeCode')} "
                f"submit={format_document_date(doc.get('submitDateTime'))}"
            )
            return doc

    logger.warning(
        f"[EDINET Discovery] {code}: {scan_days}日間スキャンで書類が見つかりませんでした"
    )
    return None




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

    直近の有報から edinetCode を取得し、年次インデックスを edinetCode でフィルタすることで
    決算期変更・商号変更にかかわらず全履歴を取得できる。

    返却リストには通常書類（docTypeCode=120）と訂正書類（130）が含まれる。
    各書類には edinet_fy_end / fiscal_year / period_type が付与されており、
    EdinetFetcher がそのまま利用できる形式。訂正書類には _is_amendment=True が付与される。

    Args:
        code: 銘柄コード（4桁または5桁）
        edinet_client: EdinetAPIClient インスタンス
        initial_scan_days: 直近スキャン日数（最新有報の発見と edinetCode 取得に使用）
        analysis_years: 取得する年数（デフォルト5）
        known_not_found_fy_ends: 後方互換のため残すが使用しない。

    Returns:
        (docs, []) のタプル。
        docs: 書類リスト（新しい年度順、末尾に訂正書類）。見つからない場合は空リスト。
    """
    # ① 直近スキャンで有報または半期報告書を1件発見 → edinetCode を取得
    # 書類の型・periodEnd には依存しない（edinetCode の取得が目的）
    recent = await _find_most_recent_filing(code, edinet_client, initial_scan_days)
    if not recent:
        return [], []

    edinet_code = str(recent.get("edinetCode") or "")
    if not edinet_code:
        logger.warning(f"[EDINET Discovery] {code}: edinetCode が取得できません")
        return [], []

    # ② 年次インデックスを並列取得
    # scan_start_year は seed 書類の periodEnd に依存せず today.year を基点とする。
    # これにより 9ヶ月・13ヶ月決算など不規則な移行期間でも過不足なくカバーできる。
    today = datetime.now().date()
    scan_start_year = today.year - analysis_years
    year_doc_lists: list[list[dict[str, Any]]] = await asyncio.gather(
        *[edinet_client.ensure_document_index_for_year(y) for y in range(scan_start_year, today.year + 1)]
    )
    all_docs: list[dict[str, Any]] = [doc for docs in year_doc_lists for doc in docs]

    # ③ edinetCode でフィルタ（有報・訂正を分類）
    annual_docs = [
        doc for doc in all_docs
        if doc.get("edinetCode") == edinet_code
        and doc.get("docTypeCode") == _ANNUAL_REPORT_DOC_TYPE
        and doc.get("periodEnd")
    ]
    amendment_candidates = [
        doc for doc in all_docs
        if doc.get("edinetCode") == edinet_code
        and doc.get("docTypeCode") == _AMENDMENT_DOC_TYPE
    ]

    # periodEnd 降順ソート → 上位 analysis_years 件を選択
    annual_docs.sort(key=lambda d: d.get("periodEnd", ""), reverse=True)
    selected = annual_docs[:analysis_years]

    # ④ edinet_fy_end / fiscal_year / period_type を付与
    docs: list[dict[str, Any]] = []
    for doc in selected:
        pe_dt = parse_date_string(str(doc.get("periodEnd") or ""))
        if not pe_dt:
            continue
        fy_end_s = pe_dt.strftime("%Y-%m-%d")
        ps_dt = parse_date_string(str(doc.get("periodStart") or ""))
        fiscal_year = ps_dt.year if ps_dt else pe_dt.year - 1
        _attach_fy_metadata(doc, fy_end_s, fiscal_year)
        docs.append(doc)

    # ⑤ 訂正書類: parentDocID が選択済み有報に対応するものを付与
    fy_meta_by_id: dict[str, tuple[str, int | None]] = {
        d["docID"]: (d.get("edinet_fy_end", ""), d.get("fiscal_year"))
        for d in docs
        if d.get("docID")
    }
    for amendment in amendment_candidates:
        parent_id = str(amendment.get("parentDocID") or "")
        if parent_id not in fy_meta_by_id:
            continue
        fy_end_a, fy_a = fy_meta_by_id[parent_id]
        amendment["edinet_fy_end"] = fy_end_a
        amendment["fiscal_year"] = fy_a
        amendment["period_type"] = "FY"
        amendment["_is_amendment"] = True
        docs.append(amendment)

    n_annual = sum(1 for d in docs if d.get("docTypeCode") == _ANNUAL_REPORT_DOC_TYPE)
    n_amend = sum(1 for d in docs if d.get("docTypeCode") == _AMENDMENT_DOC_TYPE)
    logger.info(
        f"[EDINET Discovery] {code}: 有報{n_annual}件 訂正{n_amend}件 発見"
        f" [edinetCode={edinet_code}]"
    )
    return docs, []


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
