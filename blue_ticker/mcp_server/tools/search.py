from typing import Any

from mcp.server.fastmcp import FastMCP

from blue_ticker.services.data_service import data_service
from blue_ticker.services.master_data import master_data_manager


def register_search_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def search_companies(query: str) -> list[dict[str, Any]]:
        """銘柄コードまたは名称で企業を検索します。"""
        results = await data_service.search_companies(query)
        return [dict(r) for r in results]

    @mcp.tool()
    async def search_by_sector(sector: str, limit: int = 20) -> list[dict[str, Any]]:
        """東証33業種で銘柄を検索します。業種名の部分一致で絞り込めます。"""
        results = master_data_manager.search_by_sector(sector, limit=limit)
        return [dict(r) for r in results]
