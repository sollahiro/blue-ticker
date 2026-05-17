"""
edinet_docs キャッシュの「短いキャッシュを返さない」保証テスト。

years=1 で永続キャッシュを作成後、years=3 で呼び出した場合に
短いキャッシュがそのまま返らず、EDINET を再検索することを検証する。
"""

import asyncio
import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from blue_ticker.services.edinet_fetcher import EdinetFetcher, _EDINET_DOCS_CACHE_VERSION
from blue_ticker.utils.cache import CacheManager


def _make_doc(fy_end: str) -> dict:
    return {"docID": f"S{fy_end[:4]}", "edinet_fy_end": fy_end}


@pytest.fixture
def cache_manager(tmp_path):
    return CacheManager(cache_dir=str(tmp_path), enabled=True)


@pytest.fixture
def mock_client():
    client = MagicMock()
    client.api_key = "dummy"
    return client


async def _search_annual_side_effect(code, max_years, *, known_not_found_fy_ends=frozenset()):
    return [_make_doc(f"202{5 - i}-03-31") for i in range(max_years)], []


def test_short_cache_not_returned_for_larger_request(cache_manager, mock_client):
    """years=1 のキャッシュ後、years=3 で再呼び出しすると再取得される。"""
    fetcher = EdinetFetcher(mock_client, cache_manager=cache_manager)
    fetcher._search_edinet_annual_docs = AsyncMock(side_effect=_search_annual_side_effect)

    # 1回目: years=1 で呼ぶ → LIMIT=10 件で保存
    result1 = asyncio.run(fetcher._get_annual_docs("1234", [], 1))
    assert len(result1) == 1
    assert fetcher._search_edinet_annual_docs.call_count == 1

    # 永続キャッシュを「意図的に 1 件だけ」に短縮して毒キャッシュを再現
    cache_manager.set("edinet_docs_1234", {
        "_cache_version": _EDINET_DOCS_CACHE_VERSION,
        "docs": [_make_doc("2025-03-31")],  # 1 件のみ
    })
    fetcher._doc_cache.clear()  # メモリキャッシュもリセット

    # 2回目: years=3 で呼ぶ → キャッシュが短い（1 件 < 3 件）ので再取得
    result3 = asyncio.run(fetcher._get_annual_docs("1234", [], 3))
    assert len(result3) == 3
    assert fetcher._search_edinet_annual_docs.call_count == 2  # 再取得された


def test_sufficient_cache_not_refetched(cache_manager, mock_client):
    """十分な件数のキャッシュがある場合は再取得しない。"""
    fetcher = EdinetFetcher(mock_client, cache_manager=cache_manager)
    fetcher._search_edinet_annual_docs = AsyncMock(side_effect=_search_annual_side_effect)

    # 最初に years=5 で呼んでキャッシュを作成
    asyncio.run(fetcher._get_annual_docs("5678", [], 5))
    assert fetcher._search_edinet_annual_docs.call_count == 1
    fetcher._doc_cache.clear()

    # years=3 で再呼び出し → キャッシュが十分（5 件 >= 3 件）なので再取得不要
    result = asyncio.run(fetcher._get_annual_docs("5678", [], 3))
    assert len(result) == 3
    assert fetcher._search_edinet_annual_docs.call_count == 1  # 追加取得なし
