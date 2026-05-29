from typing import Any

from mcp.server.fastmcp import FastMCP

from blue_ticker.mcp_server.sync.document_list import sync_document_list as _sync_document_list
from blue_ticker.mcp_server.tools.filing_content import register_filing_content_tools
from blue_ticker.mcp_server.tools.filings import register_filings_tools
from blue_ticker.mcp_server.tools.financial import register_financial_tools
from blue_ticker.mcp_server.tools.search import register_search_tools

mcp = FastMCP("blue-ticker")

register_search_tools(mcp)
register_filings_tools(mcp)
register_financial_tools(mcp)
register_filing_content_tools(mcp)


@mcp.tool()
async def sync_document_list(years: int = 2) -> dict[str, Any]:
    """EDINET書類一覧を最新状態に同期します（管理用）。直近 years 年分の差分を取得します。"""
    return await _sync_document_list(years=years)


def main() -> None:
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
