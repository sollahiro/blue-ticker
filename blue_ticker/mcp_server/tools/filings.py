from typing import Any

from mcp.server.fastmcp import FastMCP

from blue_ticker.constants.api import (
    EDINET_DOC_TYPE_AMENDMENT,
    EDINET_DOC_TYPE_ANNUAL_REPORT,
    EDINET_DOC_TYPE_HALF_YEAR_REPORT,
    EDINET_DOC_TYPE_QUARTERLY_REPORT,
)
from blue_ticker.services.data_service import data_service
from blue_ticker.utils.fiscal_year import format_document_date

_DOC_TYPE_LABELS: dict[str, str] = {
    EDINET_DOC_TYPE_ANNUAL_REPORT: "有価証券報告書",
    EDINET_DOC_TYPE_AMENDMENT: "訂正有価証券報告書",
    EDINET_DOC_TYPE_QUARTERLY_REPORT: "半期報告書",
    EDINET_DOC_TYPE_HALF_YEAR_REPORT: "半期報告書",
}


def _format_filing(doc: dict[str, Any]) -> dict[str, Any]:
    doc_type = str(doc.get("docTypeCode") or "")
    raw_fy_end: str = doc.get("edinet_fy_end") or ""
    return {
        "doc_id": doc.get("docID"),
        "doc_type": doc_type,
        "doc_type_label": _DOC_TYPE_LABELS.get(doc_type, str(doc.get("docDescription") or "")),
        "fy_end": raw_fy_end[:7] if raw_fy_end else None,
        "submitted_at": format_document_date(doc.get("submitDateTime") or doc.get("submitDate")) or None,
    }


def register_filings_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def get_filings(code: str, max_years: int = 5) -> dict[str, Any]:
        """銘柄コードに紐づくEDINET書類一覧を取得します。書類一覧は事前キャッシュから返します。"""
        basic = data_service.fetch_stock_basic_info(code)
        docs = await data_service.search_filings(code=code, max_years=max_years, max_documents=50)
        return {
            "code": code,
            "name": basic.get("CoName"),
            "filings": [_format_filing(d) for d in docs],
        }
