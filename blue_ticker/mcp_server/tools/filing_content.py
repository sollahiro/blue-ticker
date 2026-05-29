from typing import Any

from mcp.server.fastmcp import FastMCP

from blue_ticker.services.data_service import data_service


def register_filing_content_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def get_filing_content(
        code: str,
        doc_id: str | None = None,
        sections: list[str] | None = None,
    ) -> dict[str, Any]:
        """EDINET書類からセクションテキストを抽出します。
        doc_idを省略すると最新の有価証券報告書を使用します。
        sectionsを省略すると全セクションを返します。
        """
        try:
            return await data_service.extract_filing_content(
                code=code,
                doc_id=doc_id,
                sections=sections,
            )
        except ValueError as e:
            return {"code": code, "error": str(e)}
