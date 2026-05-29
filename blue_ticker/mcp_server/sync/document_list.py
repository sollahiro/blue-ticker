import logging
from datetime import datetime
from typing import Any

from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.infrastructure.settings import settings_store
from blue_ticker.utils.cache_paths import edinet_cache_dir

logger = logging.getLogger(__name__)


async def sync_document_list(years: int = 2) -> dict[str, Any]:
    """EDINET年次インデックスを差分更新する（cache catchup 相当）。"""
    api_key = settings_store.edinet_api_key
    if not api_key:
        return {"status": "error", "message": "EDINET APIキーが設定されていません"}

    client = EdinetAPIClient(
        api_key=api_key,
        cache_dir=str(edinet_cache_dir(settings_store.cache_dir)),
    )
    current_year = datetime.now().year
    target_years = [current_year - offset for offset in range(years)]
    entries: list[dict[str, Any]] = []
    try:
        for year in target_years:
            docs = await client.catchup_document_index_for_year(year)
            entries.append({"year": year, "documents": len(docs), "status": "synced"})
            logger.info(f"書類一覧を同期しました: {year}年 {len(docs)}件")
    finally:
        await client.close()

    return {
        "status": "ok",
        "synced_years": len(entries),
        "entries": entries,
    }
