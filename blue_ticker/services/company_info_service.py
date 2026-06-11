"""
銘柄マスタ参照サービス
"""

import logging
from typing import Any

from .master_data import master_data_manager
from blue_ticker.utils.master_types import StockSearchResult

logger = logging.getLogger(__name__)


class CompanyInfoService:
    """銘柄検索・基本情報取得を担当するサービス"""

    async def search_companies(self, query: str) -> list[StockSearchResult]:
        """銘柄コードまたは名称で企業を検索します。"""
        return master_data_manager.search(query, limit=50)

    def fetch_stock_basic_info(self, code: str) -> dict[str, Any]:
        """銘柄の基本情報を取得"""
        stock_info = master_data_manager.get_by_code(code)
        if not stock_info:
            logger.warning(f"銘柄情報が見つかりません: {code}")
            return {
                "name": "",
                "industry": "",
                "market": "",
                "code": code,
            }

        return {
            "name": stock_info.get("CoName"),
            "name_en": stock_info.get("CoNameEn", ""),
            "industry": stock_info.get("S33Nm"),
            "location": stock_info.get("Location", ""),
            "market": stock_info.get("MktNm", ""),
            "market_name": stock_info.get("MktNm", ""),
            "is_listed": stock_info.get("IsListed", False),
            "has_consolidated": stock_info.get("HasConsolidated", False),
            "edinet_code": stock_info.get("EdinetCode", ""),
            "code": code,
        }
