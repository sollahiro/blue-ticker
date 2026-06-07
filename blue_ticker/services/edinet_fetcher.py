"""
EDINETフェッチャー

EDINET APIからの有価証券報告書取得と有利子負債抽出を担当。
"""

import asyncio
import logging
import time
from collections.abc import AsyncGenerator, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TypeAlias, TypedDict, cast

from blue_ticker import __version__
from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.constants.api import (
    EDINET_DOC_DISCOVERY_LIMIT,
    EDINET_DOC_TYPE_AMENDMENT,
    EDINET_DOC_TYPE_ANNUAL_REPORT,
    EDINET_DOC_TYPE_HALF_YEAR_REPORT,
    EDINET_DOC_TYPE_QUARTERLY_REPORT,
)
from blue_ticker.analysis.order_book import extract_order_book
from blue_ticker.utils.cache import CacheManager
from blue_ticker.utils.edinet_discovery import (
    build_document_index_for_code,
    build_half_year_document_index_for_code,
)
from blue_ticker.utils.fiscal_year import format_document_date
from blue_ticker.utils.xbrl_result_types import (
    CashFlowResult,
    GrossProfitResult,
    HalfYearEdinetEntry,
    InterestBearingDebtResult,
    OperatingProfitResult,
    XbrlFactIndex,
)
from blue_ticker.services._edinet_doc_filter import (
    _amendment_doc_ids_by_year,
    _doc_ids_by_year,
    _fy_end_key,
    _is_primary_annual_doc,
    _primary_annual_docs,
    _slice_docs_preserving_amendments,
    _slice_half_year_docs,
)
from blue_ticker.services._xbrl_parse_cache import (
    _PreParsedEntry,
    _PreParsedMap,
    _extract_with_statement_scope,
    _numeric_elements_from_xbrl_parse_cache,
)
from blue_ticker.services._xbrl_record_builder import (
    _build_xbrl_record,
    _docs_from_xbrl_records,
    _employees_compat,
    _extract_bank_compat,
    _extract_bs_compat,
    _extract_cf_compat,
    _extract_da_compat,
    _extract_gp_compat,
    _extract_ibd_compat,
    _extract_ie_compat,
    _extract_nr_compat,
    _extract_op_compat,
    _extract_ppe_compat,
    _extract_tax_compat,
    _extract_xbrl_financials,
    _infer_fy_end_from_period_start,
    _infer_fy_start,
)

logger = logging.getLogger(__name__)

_EDINET_DOCS_CACHE_VERSION = __version__

_XBRL_PARSE_CACHE_VERSION = f"{__version__}:xbrl-facts-v2"


class XbrlBuildContext(TypedDict):
    docs: list[dict[str, Any]]
    pre_parsed_map: _PreParsedMap
    records: list[dict[str, Any]]


_MetricByYear: TypeAlias = dict[str, dict[str, Any]]
_AllMetrics: TypeAlias = dict[str, dict[str, Any]]
_DocCacheKey: TypeAlias = tuple[str, int] | tuple[str, int, str] | tuple[str, str]


@dataclass(frozen=True)
class ExtractorSpec:
    key: str
    label: str
    extract_fn: Callable
    result_check: Callable[[dict[str, Any]], bool] | None = None


_EXTRACTOR_SPECS: list[ExtractorSpec] = [
    ExtractorSpec("ibd", "IBD", _extract_ibd_compat),
    ExtractorSpec(
        "bank",
        "銀行財務",
        _extract_bank_compat,
        result_check=lambda r: r.get("deposits") is not None,
    ),
    ExtractorSpec(
        "ppe",
        "PPE",
        _extract_ppe_compat,
        result_check=lambda r: r.get("total") is not None,
    ),
    ExtractorSpec(
        "bs",
        "BS",
        _extract_bs_compat,
        result_check=lambda r: any(
            r.get(key) is not None
            for key in (
                "current_assets",
                "total_assets",
                "non_current_assets",
                "current_liabilities",
                "non_current_liabilities",
                "net_assets",
            )
        ),
    ),
    ExtractorSpec("gp", "GP", _extract_gp_compat),
    ExtractorSpec("ie", "IE", _extract_ie_compat),
    ExtractorSpec("tax", "TAX", _extract_tax_compat),
    ExtractorSpec("emp", "EMP", _employees_compat),
    ExtractorSpec("nr", "NR", _extract_nr_compat, result_check=lambda r: bool(r.get("found"))),
    ExtractorSpec("op", "OP", _extract_op_compat),
    ExtractorSpec("da", "DA", _extract_da_compat),
    ExtractorSpec(
        "ob",
        "OB",
        extract_order_book,
        result_check=lambda r: r.get("order_intake") is not None or r.get("order_backlog") is not None,
    ),
]

_SPEC_BY_KEY: dict[str, ExtractorSpec] = {spec.key: spec for spec in _EXTRACTOR_SPECS}


class EdinetFetcher:
    """EDINETからの有価証券報告書取得・有利子負債抽出"""

    def __init__(
        self,
        edinet_client: EdinetAPIClient | None,
        *,
        cache_manager: CacheManager | None = None,
    ) -> None:
        self.edinet_client = edinet_client
        self.cache_manager = cache_manager
        self._doc_cache: dict[_DocCacheKey, list[dict[str, Any]]] = {}
        self._doc_locks: dict[_DocCacheKey, asyncio.Lock] = {}

    async def _get_annual_docs(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
    ) -> list[dict[str, Any]]:
        """検索済みEDINET書類をインスタンス内でキャッシュ。

        - キャッシュキー: edinet_docs_{code}（max_years 非依存）
        - 保存数: max(EDINET_DOC_DISCOVERY_LIMIT, max_years)
        - 返却: docs[:max_years] で slice
        - キャッシュが max_years より短い場合は再取得して上書き
        """
        lock_key: tuple[str, str] = (code, "FY")
        persistent_key = f"edinet_docs_{code}"
        save_count = max(EDINET_DOC_DISCOVERY_LIMIT, max_years)

        if lock_key not in self._doc_locks:
            self._doc_locks[lock_key] = asyncio.Lock()
        async with self._doc_locks[lock_key]:
            # メモリキャッシュが十分な通常書類を持っていれば即返す
            mem = self._doc_cache.get(lock_key)
            if mem is not None:
                regular_mem = [d for d in mem if _is_primary_annual_doc(d)]
                if len(regular_mem) >= max_years:
                    return _slice_docs_preserving_amendments(mem, max_years)

            # 永続キャッシュが十分な通常書類を持っていれば使う
            if self.cache_manager is not None:
                cached = await self.cache_manager.async_get(persistent_key)
                if (
                    isinstance(cached, dict)
                    and cached.get("_cache_version") == _EDINET_DOCS_CACHE_VERSION
                    and isinstance(cached.get("docs"), list)
                ):
                    cached_regular = [
                        d for d in cached["docs"] if _is_primary_annual_doc(d)
                    ]
                    if len(cached_regular) >= max_years:
                        self._doc_cache[lock_key] = cached["docs"]
                        return _slice_docs_preserving_amendments(cached["docs"], max_years)

            # financial_data 由来の docs_from_records を試みる（max_years 以上あれば採用）
            annual_records = [r for r in financial_data if r.get("CurPerType") == "FY"]
            docs_from_records = _docs_from_xbrl_records(annual_records)

            if docs_from_records and len(docs_from_records) >= max_years:
                docs = docs_from_records[:save_count]
            else:
                docs, _ = await self._search_edinet_annual_docs(code, save_count)

            self._doc_cache[lock_key] = docs
            if self.cache_manager is not None and docs:
                await self.cache_manager.async_set(
                    persistent_key,
                    {
                        "_cache_version": _EDINET_DOCS_CACHE_VERSION,
                        "docs": docs,
                    },
                )
            return _slice_docs_preserving_amendments(docs, max_years)

    async def _search_edinet_annual_docs(
        self,
        code: str,
        max_years: int,
    ) -> tuple[list[dict[str, Any]], list[str]]:
        """EDINET の有価証券報告書を発見する。"""
        if not self.edinet_client:
            return [], []
        return await build_document_index_for_code(
            code,
            self.edinet_client,
            analysis_years=max_years,
        )

    async def _search_edinet_half_docs(
        self,
        code: str,
        max_years: int,
    ) -> list[dict[str, Any]]:
        """EDINET の半期/2Q報告書を発見する。"""
        if not self.edinet_client:
            return []
        return await build_half_year_document_index_for_code(
            code,
            self.edinet_client,
            analysis_years=max_years,
        )

    def _prepare_q2_records(
        self,
        financial_data: list[dict[str, Any]],
        max_years: int,
    ) -> list[dict[str, Any]]:
        """2Qレコードを抽出し、年度末ごとに最新開示日へ集約する。"""
        from datetime import datetime as _dt
        from blue_ticker.utils.fiscal_year import parse_date_string as _parse

        now = _dt.now()
        q2_records_raw: list[dict[str, Any]] = []
        for record in financial_data:
            if record.get("CurPerType") != "2Q":
                continue
            disc_date = record.get("DiscDate", "")
            if disc_date:
                dt = _parse(disc_date)
                if dt and dt > now:
                    continue
            q2_records_raw.append(record)

        seen_fy_ends: dict[str, dict[str, Any]] = {}
        for record in q2_records_raw:
            fy_end = record.get("CurFYEn", "")
            if fy_end not in seen_fy_ends or record.get("DiscDate", "") > seen_fy_ends[fy_end].get("DiscDate", ""):
                seen_fy_ends[fy_end] = record

        return sorted(
            seen_fy_ends.values(),
            key=lambda item: item.get("CurFYEn", ""),
            reverse=True,
        )[:max_years]

    async def _get_half_year_docs(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
    ) -> list[dict[str, Any]]:
        """半期書類をキャッシュ経由で返す。

        - キャッシュキー: edinet_docs_{code}_2Q（max_years 非依存）
        - 保存数: max(EDINET_DOC_DISCOVERY_LIMIT, max_years)
        - 返却: docs[:max_years] で slice
        - キャッシュが max_years より短い場合は再取得して上書き
        """
        lock_key: tuple[str, str] = (code, "2Q")
        persistent_key = f"edinet_docs_{code}_2Q"
        save_count = max(EDINET_DOC_DISCOVERY_LIMIT, max_years)

        if lock_key not in self._doc_locks:
            self._doc_locks[lock_key] = asyncio.Lock()
        async with self._doc_locks[lock_key]:
            # メモリキャッシュが十分な通常書類を持っていれば即返す
            mem = self._doc_cache.get(lock_key)
            if mem is not None:
                regular_mem = [d for d in mem if not d.get("_is_amendment")]
                if len(regular_mem) >= max_years:
                    return _slice_half_year_docs(mem, max_years)

            # 永続キャッシュが十分な通常書類を持っていれば使う
            if self.cache_manager is not None:
                cached = await self.cache_manager.async_get(persistent_key)
                if (
                    isinstance(cached, dict)
                    and cached.get("_cache_version") == _EDINET_DOCS_CACHE_VERSION
                    and isinstance(cached.get("docs"), list)
                ):
                    cached_regular = [d for d in cached["docs"] if not d.get("_is_amendment")]
                    if len(cached_regular) >= max_years:
                        self._doc_cache[lock_key] = cached["docs"]
                        return _slice_half_year_docs(cached["docs"], max_years)

            if not self.edinet_client:
                return []

            # financial_data 由来の docs_from_records を試みる（max_years 以上あれば採用）
            records = self._prepare_q2_records(financial_data, save_count)
            docs_from_records = _docs_from_xbrl_records(records)

            if docs_from_records and len(docs_from_records) >= max_years:
                docs = docs_from_records[:save_count]
            else:
                docs = await self._search_edinet_half_docs(code, save_count)

            self._doc_cache[lock_key] = docs
            if self.cache_manager is not None:
                await self.cache_manager.async_set(
                    persistent_key,
                    {"_cache_version": _EDINET_DOCS_CACHE_VERSION, "docs": docs},
                )
            return _slice_half_year_docs(docs, max_years)

    async def fetch_latest_annual_report(
        self,
        code: str,
    ) -> dict[str, Any] | None:
        """最新の有価証券報告書(120)を1件取得する。"""
        docs, _ = await self._search_edinet_annual_docs(code, 10)
        annual_reports = [
            doc for doc in docs if doc.get("docTypeCode") == EDINET_DOC_TYPE_ANNUAL_REPORT
        ]
        if annual_reports:
            return sorted(annual_reports, key=lambda x: x.get("submitDateTime", ""), reverse=True)[0]
        return None

    async def predownload_and_parse(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
    ) -> _PreParsedMap:
        """全年度のXBRL文書を一括ダウンロード・パースする。

        Returns: { "YYYYMMDD": (xbrl_dir_path, pre_parsed_dict) }
        """
        if not self.edinet_client or not self.edinet_client.api_key:
            return {}
        docs = await self._get_annual_docs(code, financial_data, max_years)
        return await self._download_and_parse_docs(docs, code)

    async def _download_and_parse_docs(
        self,
        docs: list[dict[str, Any]],
        code: str,
    ) -> _PreParsedMap:
        """XBRL文書を一括ダウンロード・パースする。"""
        from blue_ticker.analysis.xbrl_utils import (
            collect_all_numeric_facts,
            fact_index_to_numeric_elements,
        )

        if self.edinet_client is None:
            return {}
        client = self.edinet_client

        async def _dl_parse(doc: dict[str, Any]) -> tuple[str, _PreParsedEntry | None]:
            fy_end_8 = _fy_end_key(doc.get("edinet_fy_end"))
            doc_id = doc["docID"]
            if not fy_end_8:
                return "", None
            parse_cache_key = f"xbrl_parsed_{doc_id}"
            total_start = time.perf_counter()
            download_elapsed = 0.0
            cache_read_elapsed = 0.0
            parse_elapsed = 0.0
            cache_write_elapsed = 0.0

            def log_profile(cache_status: str) -> None:
                logger.info(
                    "[PROFILE] %s %s %s: download=%.2fs cache_read=%.2fs parse=%.2fs cache_write=%.2fs total=%.2fs",
                    code,
                    fy_end_8,
                    cache_status,
                    download_elapsed,
                    cache_read_elapsed,
                    parse_elapsed,
                    cache_write_elapsed,
                    time.perf_counter() - total_start,
                )

            try:
                download_start = time.perf_counter()
                xbrl_dir = await asyncio.wait_for(
                    client.download_document(doc_id, 1),
                    timeout=30.0,
                )
                download_elapsed = time.perf_counter() - download_start
                if not xbrl_dir:
                    log_profile("missing_xbrl")
                    return fy_end_8, None
                xbrl_path = Path(xbrl_dir)
                if self.cache_manager is not None:
                    cache_read_start = time.perf_counter()
                    cached = await self.cache_manager.async_get(parse_cache_key)
                    cache_read_elapsed = time.perf_counter() - cache_read_start
                    cached_numeric = (
                        _numeric_elements_from_xbrl_parse_cache(cached.get("data"))
                        if isinstance(cached, dict)
                        else None
                    )
                    if (
                        isinstance(cached, dict)
                        and cached.get("_cache_version") == _XBRL_PARSE_CACHE_VERSION
                        and cached_numeric is not None
                    ):
                        log_profile("cache_hit")
                        return fy_end_8, (
                            xbrl_path,
                            cached_numeric,
                            cast(XbrlFactIndex, cached["data"]),
                        )
                parse_start = time.perf_counter()
                pre_parsed_facts = collect_all_numeric_facts(xbrl_path)
                parse_elapsed = time.perf_counter() - parse_start
                pre_parsed = fact_index_to_numeric_elements(pre_parsed_facts)
                if self.cache_manager is not None:
                    cache_write_start = time.perf_counter()
                    await self.cache_manager.async_set(parse_cache_key, {
                        "_cache_version": _XBRL_PARSE_CACHE_VERSION,
                        "data": pre_parsed_facts,
                    })
                    cache_write_elapsed = time.perf_counter() - cache_write_start
                log_profile("cache_miss" if self.cache_manager is not None else "cache_disabled")
                return fy_end_8, (xbrl_path, pre_parsed, pre_parsed_facts)
            except asyncio.TimeoutError:
                logger.warning(f"[PARSE] {code} {fy_end_8}: XBRLダウンロードタイムアウト(30s)")
                return fy_end_8, None
            except Exception as e:
                logger.warning(f"[PARSE] {code} {fy_end_8}: パースエラー - {e}")
                return fy_end_8, None

        _t0 = time.perf_counter()
        raw = await asyncio.gather(*[_dl_parse(doc) for doc in docs], return_exceptions=True)
        out: _PreParsedMap = {}
        for res in raw:
            if isinstance(res, BaseException):
                continue
            k, v = res
            if k and v is not None:
                # 原本を優先: _slice_docs_preserving_amendments は原本を先に並べるため
                # setdefault により訂正報告書が原本エントリを上書きしない
                out.setdefault(k, v)
        logger.info(f"[PARSE] {code}: XBRL一括パース完了 {len(out)}件 {time.perf_counter() - _t0:.2f}s")
        return out

    async def _run_extraction(
        self,
        doc: dict[str, Any],
        code: str,
        prefix: str,
        extract_fn: Callable,
        *,
        result_check: Callable[[dict[str, Any]], bool] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> tuple[str, dict[str, Any] | None]:
        fy_end_8 = _fy_end_key(doc.get("edinet_fy_end"))
        if not fy_end_8:
            return "", None
        if self.edinet_client is None:
            return fy_end_8, None
        client = self.edinet_client
        try:
            if pre_parsed_map is not None and fy_end_8 in pre_parsed_map:
                entry = pre_parsed_map[fy_end_8]
                xbrl_path = entry[0]
                result = _extract_with_statement_scope(entry, prefix.lower(), extract_fn)
            else:
                xbrl_dir = await asyncio.wait_for(
                    client.download_document(doc["docID"], 1),
                    timeout=30.0,
                )
                if not xbrl_dir:
                    logger.warning(f"[{prefix}] {code} {fy_end_8}: XBRLダウンロード失敗")
                    return fy_end_8, None
                result = extract_fn(Path(xbrl_dir))
            if result_check is not None and not result_check(result):
                return fy_end_8, None
            result["docID"] = doc["docID"]
            logger.info(f"[{prefix}] {code} {fy_end_8}: docID={doc['docID']}")
            return fy_end_8, result
        except asyncio.TimeoutError:
            logger.warning(f"[{prefix}] {code} {fy_end_8}: XBRLダウンロードタイムアウト(30s)")
            return fy_end_8, None
        except Exception as e:
            logger.warning(f"[{prefix}] {code} {fy_end_8}: 抽出エラー - {e}")
            return fy_end_8, None

    def _collect_results(
        self,
        results: list[tuple[str, dict[str, Any] | None] | BaseException],
        code: str,
        prefix: str,
    ) -> _MetricByYear:
        out: _MetricByYear = {}
        for res in results:
            if isinstance(res, BaseException):
                logger.warning(f"[{prefix}] {code} gather エラー: {res}")
                continue
            k, v = res
            if k and v is not None:
                out[k] = v
        return out

    async def fetch_edinet_data_async(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_documents: int = 10,
    ) -> dict[str, Any]:
        """EDINETデータを非同期で取得"""
        if not self.edinet_client:
            return {}
        try:
            results = {}
            async for data in self.fetch_edinet_reports_stream(
                code, financial_data, max_documents
            ):
                fy_key = data["fy_key"]
                report = data["report"]
                fy_key_str = str(fy_key)
                if fy_key_str not in results:
                    results[fy_key_str] = []
                results[fy_key_str].append(report)

            return results
        except Exception as e:
            logger.error(f"EDINET非同期データ取得エラー: {code} - {e}", exc_info=True)
            return {}

    async def fetch_edinet_reports_stream(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_documents: int = 20,
    ) -> AsyncGenerator[dict[str, Any], None]:
        """EDINET書類を取得し、準備ができた段階で順次yieldする"""
        if not self.edinet_client or not self.edinet_client.api_key:
            logger.warning(f"EDINETクライアントが利用不可またはAPIキー未設定: code={code}")
            return

        try:
            all_docs = await self._get_annual_docs(code, financial_data, max_documents)

            if not all_docs:
                logger.info(f"EDINET書類が見つかりませんでした: code={code}")
                return

            all_docs.sort(key=lambda x: x.get("submitDateTime", ""), reverse=True)

            for doc in all_docs:
                doc_id = doc["docID"]
                dt = doc.get("docTypeCode")
                if dt == EDINET_DOC_TYPE_ANNUAL_REPORT:
                    label = "有価証券報告書"
                elif dt == EDINET_DOC_TYPE_AMENDMENT:
                    label = "訂正有価証券報告書"
                elif dt in {EDINET_DOC_TYPE_QUARTERLY_REPORT, EDINET_DOC_TYPE_HALF_YEAR_REPORT}:
                    label = "半期報告書"
                else:
                    label = str(doc.get("docDescription") or "")
                year = doc.get("fiscal_year")
                fy_key = doc.get("edinet_fy_end") or str(year)

                report_info = {
                    "docID": doc_id,
                    "submitDate": format_document_date(doc.get("submitDateTime")),
                    "docType": label,
                    "docTypeCode": dt,
                    "fiscal_year": year,
                    "edinet_fy_end": fy_key,
                }

                yield {"year": year, "fy_key": fy_key, "report": report_info}

        except Exception as e:
            logger.error(f"EDINETストリーミング取得エラー: {code} - {e}", exc_info=True)

    async def fetch_edinet_reports(
        self,
        code: str,
        years: list[int],
        annual_data: list[dict[str, Any]] | None = None,
        progress_callback: Callable | None = None,
        max_documents: int = 20,
    ) -> dict[int, list[dict[str, Any]]]:
        """指定年度の有価証券報告書を取得"""
        results = {}
        async for data in self.fetch_edinet_reports_stream(
            code, annual_data or [], max_documents
        ):
            fy_key = data["fy_key"]
            report = data["report"]
            fy_key_str = str(fy_key)
            if fy_key_str not in results:
                results[fy_key_str] = []

            found = False
            for i, existing in enumerate(results[fy_key_str]):
                if existing["docID"] == report["docID"]:
                    results[fy_key_str][i] = report
                    found = True
                    break
            if not found:
                results[fy_key_str].append(report)

        return results

    async def get_doc_ids_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
    ) -> dict[str, str]:
        """年度別にEDINET有価証券報告書のdocIDを返す。Returns: { "YYYYMMDD": docID }"""
        if not self.edinet_client or not self.edinet_client.api_key:
            return {}
        if docs is None:
            docs = await self._get_annual_docs(code, financial_data, max_years)
        else:
            docs = _slice_docs_preserving_amendments(docs, max_years)
        result: dict[str, str] = {}
        result.update(_doc_ids_by_year(docs))
        return result

    async def get_amendment_doc_ids_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
    ) -> dict[str, str]:
        """年度別に訂正有価証券報告書のdocIDを返す。Returns: { "YYYYMMDD": docID }"""
        if not self.edinet_client or not self.edinet_client.api_key:
            return {}
        if docs is None:
            docs = await self._get_annual_docs(code, financial_data, max_years)
        else:
            docs = _slice_docs_preserving_amendments(docs, max_years)
        return _amendment_doc_ids_by_year(docs)

    async def _extract_metric_by_year(
        self,
        spec: ExtractorSpec,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        if not self.edinet_client or not self.edinet_client.api_key:
            return {}
        if docs is None:
            docs = await self._get_annual_docs(code, financial_data, max_years)
        else:
            docs = _slice_docs_preserving_amendments(docs, max_years)
        docs = _primary_annual_docs(docs)
        logger.info(f"[{spec.label}] {code}: {len(docs)}件のEDINET文書を検索")
        _t0 = time.perf_counter()
        results = await asyncio.gather(
            *[
                self._run_extraction(
                    doc,
                    code,
                    spec.label,
                    spec.extract_fn,
                    result_check=spec.result_check,
                    pre_parsed_map=pre_parsed_map,
                )
                for doc in docs
            ],
            return_exceptions=True,
        )
        by_year = self._collect_results(results, code, spec.label)
        logger.info(f"[{spec.label}] {code}: 抽出完了 {len(by_year)}件 {time.perf_counter() - _t0:.2f}s")
        return by_year

    async def extract_all_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _AllMetrics:
        """全メトリクスを並列抽出。Returns: {"ibd": {...}, "gp": {...}, ..., "doc_ids": {...}}"""
        metric_results = await asyncio.gather(*[
            self._extract_metric_by_year(
                spec,
                code,
                financial_data,
                max_years,
                docs=docs,
                pre_parsed_map=pre_parsed_map,
            )
            for spec in _EXTRACTOR_SPECS
        ])
        doc_ids, amendment_doc_ids = await asyncio.gather(
            self.get_doc_ids_by_year(code, financial_data, max_years, docs=docs),
            self.get_amendment_doc_ids_by_year(code, financial_data, max_years, docs=docs),
        )
        out: _AllMetrics = {
            spec.key: result
            for spec, result in zip(_EXTRACTOR_SPECS, metric_results)
        }
        out["doc_ids"] = doc_ids
        out["amendment_doc_ids"] = amendment_doc_ids
        return out

    async def extract_ibd_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        """年度別に有利子負債を抽出。Returns: { "YYYYMMDD": ibd_result_dict }"""
        return await self._extract_metric_by_year(_SPEC_BY_KEY["ibd"], code, financial_data, max_years, docs=docs, pre_parsed_map=pre_parsed_map)

    async def extract_half_year_edinet_data(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> dict[str, HalfYearEdinetEntry]:
        """2Q期間のEDINETデータ（GrossProfit + CF + IBD）を年度別に抽出。

        Returns: { "YYYYMMDD": {"gp": gp_result_dict, "cf": cf_result_dict, "ibd": ibd_result_dict} }
        """
        if not self.edinet_client or not self.edinet_client.api_key:
            return {}
        if docs is None:
            docs = await self._get_half_year_docs(code, financial_data, max_years)
        if not docs:
            return {}
        logger.info(f"[HALF-EDINET] {code}: {len(docs)}件の2Q文書を検索")

        if pre_parsed_map is None:
            pre_parsed_map = await self._download_and_parse_docs(docs, code)

        out: dict[str, HalfYearEdinetEntry] = {}
        for doc in docs:
            fy_end_8 = _fy_end_key(doc.get("edinet_fy_end"))
            if not fy_end_8 or fy_end_8 not in pre_parsed_map:
                continue
            entry = pre_parsed_map[fy_end_8]
            gp = cast(
                GrossProfitResult,
                _extract_with_statement_scope(entry, "gp", _extract_gp_compat),
            )
            op = cast(
                OperatingProfitResult,
                _extract_with_statement_scope(entry, "op", _extract_op_compat),
            )
            cf = cast(
                CashFlowResult,
                _extract_with_statement_scope(entry, "da", _extract_cf_compat),
            )
            ibd = cast(
                InterestBearingDebtResult,
                _extract_with_statement_scope(entry, "ibd", _extract_ibd_compat),
            )
            gp["docID"] = doc["docID"]
            op["docID"] = doc["docID"]
            logger.info(
                f"[HALF-EDINET] {code} {fy_end_8}: "
                f"gp={gp.get('current')}, op={op.get('current')}, cfo={cf['cfo'].get('current')}, "
                f"cfi={cf['cfi'].get('current')}, ibd={ibd.get('current')}, docID={doc['docID']}"
            )
            out[fy_end_8] = {"gp": gp, "op": op, "cf": cf, "ibd": ibd}

        logger.info(f"[HALF-EDINET] {code}: 半期EDINETデータ抽出完了 {len(out)}件")
        return out

    async def extract_employees_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        """年度別に従業員数を抽出。Returns: { "YYYYMMDD": employees_result_dict }"""
        return await self._extract_metric_by_year(_SPEC_BY_KEY["emp"], code, financial_data, max_years, docs=docs, pre_parsed_map=pre_parsed_map)

    async def extract_net_revenue_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        """年度別に IFRS 純収益・事業利益を抽出。Returns: { "YYYYMMDD": nr_result_dict }"""
        return await self._extract_metric_by_year(_SPEC_BY_KEY["nr"], code, financial_data, max_years, docs=docs, pre_parsed_map=pre_parsed_map)

    async def extract_gross_profit_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        """年度別に売上総利益を抽出。Returns: { "YYYYMMDD": gp_result_dict }"""
        return await self._extract_metric_by_year(_SPEC_BY_KEY["gp"], code, financial_data, max_years, docs=docs, pre_parsed_map=pre_parsed_map)

    async def extract_tax_expense_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        """年度別に税引前利益・法人税等を抽出。Returns: { "YYYYMMDD": tax_result_dict }"""
        return await self._extract_metric_by_year(_SPEC_BY_KEY["tax"], code, financial_data, max_years, docs=docs, pre_parsed_map=pre_parsed_map)

    async def extract_interest_expense_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        """年度別に支払利息（金融費用）を抽出。Returns: { "YYYYMMDD": ie_result_dict }"""
        return await self._extract_metric_by_year(_SPEC_BY_KEY["ie"], code, financial_data, max_years, docs=docs, pre_parsed_map=pre_parsed_map)

    async def extract_operating_profit_by_year(
        self,
        code: str,
        financial_data: list[dict[str, Any]],
        max_years: int,
        *,
        docs: list[dict[str, Any]] | None = None,
        pre_parsed_map: _PreParsedMap | None = None,
    ) -> _MetricByYear:
        """年度別に営業利益（または経常利益）を抽出。Returns: { "YYYYMMDD": op_result_dict }"""
        return await self._extract_metric_by_year(_SPEC_BY_KEY["op"], code, financial_data, max_years, docs=docs, pre_parsed_map=pre_parsed_map)

    async def build_xbrl_annual_records(
        self,
        code: str,
        max_years: int,
        docs: list[dict[str, Any]] | None = None,
    ) -> list[dict[str, Any]]:
        """XBRL から年度財務レコードを構築する。

        calculate_metrics_flexible へ渡せる形式の年度レコードリストを返す。
        各レコードは CurFYEn/CurFYSt/Sales/OP/NP/NetAssets/CFO/CFI を含む。
        値はすべて円単位。

        Args:
            code: 銘柄コード
            max_years: 取得する最大年数
            docs: 事前に取得した EDINET 書類リスト（省略時は自動発見）

        Returns:
            年度レコードリスト（新しい年度順）
        """
        context = await self.build_xbrl_annual_context(code, max_years, docs=docs)
        return context["records"]

    async def build_xbrl_annual_context(
        self,
        code: str,
        max_years: int,
        docs: list[dict[str, Any]] | None = None,
    ) -> XbrlBuildContext:
        """年度財務レコードと、その構築に使った XBRL 事前パース結果を返す。"""
        if not self.edinet_client:
            return {"docs": [], "pre_parsed_map": {}, "records": []}

        if docs is None:
            docs = await self._get_annual_docs(code, [], max_years)
        if not docs:
            return {"docs": [], "pre_parsed_map": {}, "records": []}

        pre_parsed_map = await self._download_and_parse_docs(docs, code)
        records = self._build_annual_records_from_pre_parsed(code, docs, pre_parsed_map)
        return {"docs": docs, "pre_parsed_map": pre_parsed_map, "records": records}

    def _build_annual_records_from_pre_parsed(
        self,
        code: str,
        docs: list[dict[str, Any]],
        pre_parsed_map: _PreParsedMap,
    ) -> list[dict[str, Any]]:
        # 訂正書類（_is_amendment=True）は pre_parsed_map で元書類の値を上書き済みのため
        # records 構築はオリジナル書類のみを対象とし、訂正書類の XBRL データは
        # _download_and_parse_docs の gather 結果で適用される。
        records: list[dict[str, Any]] = []
        for doc in docs:
            if doc.get("_is_amendment"):
                continue  # 訂正書類は pre_parsed_map 経由でオリジナルに上書き済み

            fy_end_8 = _fy_end_key(doc.get("edinet_fy_end"))
            fy_end = doc.get("edinet_fy_end", "")  # YYYY-MM-DD
            if not fy_end or fy_end_8 not in pre_parsed_map:
                continue

            fin = _extract_xbrl_financials(pre_parsed_map[fy_end_8])
            record = _build_xbrl_record(
                fin,
                code,
                doc_id=doc.get("docID"),
                fy_end=fy_end,
                fy_st=_infer_fy_start(fy_end),
                submit_date=format_document_date(doc.get("submitDateTime")),
                period_type="FY",
            )
            records.append(record)
            logger.info(
                f"[XBRL-IS] {code} {fy_end}: "
                f"Sales={record['Sales']}, OP={record['OP']}, NP={record['NP']}, "
                f"NetAssets={record['NetAssets']}, CFO={record['CFO']}, CFI={record['CFI']}"
            )

        return records

    async def build_xbrl_half_year_records(
        self,
        code: str,
        max_years: int,
        docs: list[dict[str, Any]] | None = None,
    ) -> list[dict[str, Any]]:
        """XBRL から2Q財務レコードを構築する。

        build_half_year_periods() へ渡せる形式の半期累計レコードを返す。
        値はすべて円単位。
        """
        context = await self.build_xbrl_half_year_context(code, max_years, docs=docs)
        return context["records"]

    async def build_xbrl_half_year_context(
        self,
        code: str,
        max_years: int,
        docs: list[dict[str, Any]] | None = None,
    ) -> XbrlBuildContext:
        """2Q財務レコードと、その構築に使った XBRL 事前パース結果を返す。"""
        if not self.edinet_client:
            return {"docs": [], "pre_parsed_map": {}, "records": []}

        if docs is None:
            docs = await self._get_half_year_docs(code, [], max_years)
        if not docs:
            return {"docs": [], "pre_parsed_map": {}, "records": []}

        pre_parsed_map = await self._download_and_parse_docs(docs, code)
        records = self._build_half_year_records_from_pre_parsed(code, docs, pre_parsed_map)
        return {"docs": docs, "pre_parsed_map": pre_parsed_map, "records": records}

    def _build_half_year_records_from_pre_parsed(
        self,
        code: str,
        docs: list[dict[str, Any]],
        pre_parsed_map: _PreParsedMap,
    ) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for doc in docs:
            fy_end = str(doc.get("edinet_fy_end") or "")
            period_start = str(doc.get("edinet_period_start") or doc.get("periodStart") or "")
            period_end = str(doc.get("edinet_period_end") or doc.get("periodEnd") or "")
            if not fy_end and period_start:
                fy_end = _infer_fy_end_from_period_start(period_start)
            fy_end_8 = _fy_end_key(fy_end)
            if not fy_end or fy_end_8 not in pre_parsed_map:
                continue

            fin = _extract_xbrl_financials(pre_parsed_map[fy_end_8])
            record = _build_xbrl_record(
                fin,
                code,
                doc_id=doc.get("docID"),
                fy_end=fy_end,
                fy_st=period_start or _infer_fy_start(fy_end),
                submit_date=format_document_date(doc.get("submitDateTime")),
                period_type="2Q",
                period_start=period_start,
                period_end=period_end,
            )
            records.append(record)
            logger.info(
                f"[XBRL-2Q] {code} {fy_end}: "
                f"Sales={record['Sales']}, OP={record['OP']}, NP={record['NP']}, "
                f"NetAssets={record['NetAssets']}, CFO={record['CFO']}, CFI={record['CFI']}"
            )

        return records
