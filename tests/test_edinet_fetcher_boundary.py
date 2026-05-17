import logging
from unittest.mock import AsyncMock, Mock
from pathlib import Path

import pytest

from blue_ticker import __version__
from blue_ticker.services.edinet_fetcher import EdinetFetcher
from blue_ticker.utils.cache import CacheManager


def _financial_record(
    fiscal_year_start: str,
    fiscal_year_end: str,
    disclosed_date: str,
    period_type: str = "FY",
) -> dict:
    return {
        "CurFYSt": fiscal_year_start,
        "CurFYEn": fiscal_year_end,
        "DiscDate": disclosed_date,
        "CurPerType": period_type,
    }


@pytest.mark.asyncio
async def test_get_annual_docs_falls_back_to_edinet_discovery_without_doc_ids() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._search_edinet_annual_docs = AsyncMock(return_value=([{"docID": "S100TEST"}], []))  # type: ignore[method-assign]

    docs = await fetcher._get_annual_docs(
        "72030",
        [
            _financial_record("2023-04-01", "2024-03-31", "2024-06-01"),
            _financial_record("2022-04-01", "2023-03-31", "2023-06-01"),
        ],
        1,
    )

    assert docs == [{"docID": "S100TEST"}]
    # save_count = max(EDINET_DOC_DISCOVERY_LIMIT=10, max_years=1) = 10
    fetcher._search_edinet_annual_docs.assert_awaited_once_with("72030", 10, known_not_found_fy_ends=frozenset())


@pytest.mark.asyncio
async def test_fetch_latest_annual_report_selects_latest_120_doc() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    docs = [
        {"docID": "OLD", "docTypeCode": "120", "submitDateTime": "2023-06-01T10:00:00"},
        {"docID": "Q2", "docTypeCode": "140", "submitDateTime": "2024-02-01T10:00:00"},
        {"docID": "NEW", "docTypeCode": "120", "submitDateTime": "2024-06-01T10:00:00"},
    ]
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._search_edinet_annual_docs = AsyncMock(return_value=(docs, []))  # type: ignore[method-assign]

    doc = await fetcher.fetch_latest_annual_report("72030")

    assert doc is not None
    assert doc["docID"] == "NEW"


@pytest.mark.asyncio
async def test_get_half_year_docs_calls_discovery_once_on_repeated_calls() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._search_edinet_half_docs = AsyncMock(return_value=[{"docID": "S100HALF"}])  # type: ignore[method-assign]
    financial_data = [
        _financial_record("2023-04-01", "2024-03-31", "2023-11-10", period_type="2Q"),
    ]

    first = await fetcher._get_half_year_docs("72030", financial_data, 1)
    second = await fetcher._get_half_year_docs("72030", financial_data, 1)

    assert first == [{"docID": "S100HALF"}]
    assert second == [{"docID": "S100HALF"}]
    # save_count = max(10, 1) = 10
    fetcher._search_edinet_half_docs.assert_awaited_once_with("72030", 10)


@pytest.mark.asyncio
async def test_get_annual_docs_reads_from_persistent_cache(tmp_path) -> None:
    code = "72030"
    max_years = 1
    cache_manager = CacheManager(cache_dir=str(tmp_path))
    cache_manager.set(
        f"edinet_docs_{code}",
        {
            "_cache_version": __version__,
            "docs": [{"docID": "S100CACHED"}],
        },
    )
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client, cache_manager=cache_manager)

    docs = await fetcher._get_annual_docs(
        code,
        [_financial_record("2023-04-01", "2024-03-31", "2024-06-01")],
        max_years,
    )

    assert docs == [{"docID": "S100CACHED"}]


@pytest.mark.asyncio
async def test_extract_metric_uses_provided_docs_without_doc_discovery() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._get_annual_docs = AsyncMock(side_effect=AssertionError("doc discovery should be skipped"))  # type: ignore[method-assign]
    fetcher._run_extraction = AsyncMock(return_value=("20240331", {"current": 1.0}))  # type: ignore[method-assign]
    docs = [
        {"docID": "S100ANNUAL", "docTypeCode": "120", "edinet_fy_end": "2024-03-31"},
        {"docID": "S100OLD", "docTypeCode": "120", "edinet_fy_end": "2023-03-31"},
        {
            "docID": "S100AMEND",
            "docTypeCode": "130",
            "edinet_fy_end": "2024-03-31",
            "_is_amendment": True,
        },
    ]

    result = await fetcher.extract_gross_profit_by_year("72030", [], 1, docs=docs)

    assert result == {"20240331": {"current": 1.0}}
    fetcher._get_annual_docs.assert_not_awaited()
    fetcher._run_extraction.assert_awaited_once()
    assert fetcher._run_extraction.await_args is not None
    assert fetcher._run_extraction.await_args.args[0]["docID"] == "S100ANNUAL"


@pytest.mark.asyncio
async def test_doc_id_maps_slice_provided_docs_to_max_years() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._get_annual_docs = AsyncMock(side_effect=AssertionError("doc discovery should be skipped"))  # type: ignore[method-assign]
    docs = [
        {"docID": "S100NEW", "docTypeCode": "120", "edinet_fy_end": "2025-03-31"},
        {"docID": "S100OLD", "docTypeCode": "120", "edinet_fy_end": "2024-03-31"},
        {
            "docID": "S100NEWAMEND",
            "docTypeCode": "130",
            "edinet_fy_end": "2025-03-31",
            "_is_amendment": True,
        },
        {
            "docID": "S100OLDAMEND",
            "docTypeCode": "130",
            "edinet_fy_end": "2024-03-31",
            "_is_amendment": True,
        },
    ]

    doc_ids = await fetcher.get_doc_ids_by_year("72030", [], 1, docs=docs)
    amendment_doc_ids = await fetcher.get_amendment_doc_ids_by_year("72030", [], 1, docs=docs)

    assert doc_ids == {"20250331": "S100NEW"}
    assert amendment_doc_ids == {"20250331": "S100NEWAMEND"}
    fetcher._get_annual_docs.assert_not_awaited()


@pytest.mark.asyncio
async def test_download_and_parse_docs_logs_profile_for_cache_miss_and_hit(tmp_path, caplog) -> None:
    cache_manager = CacheManager(cache_dir=str(tmp_path / "cache"), enabled=True)
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    edinet_client.download_document = AsyncMock(return_value=tmp_path / "xbrl")
    (tmp_path / "xbrl").mkdir()
    fetcher = EdinetFetcher(edinet_client=edinet_client, cache_manager=cache_manager)
    docs = [{"docID": "S100PROFILE", "edinet_fy_end": "2024-03-31"}]
    caplog.set_level(logging.INFO, logger="blue_ticker.services.edinet_fetcher")

    await fetcher._download_and_parse_docs(docs, "72030")
    await fetcher._download_and_parse_docs(docs, "72030")

    messages = "\n".join(record.getMessage() for record in caplog.records)
    assert "[PROFILE] 72030 20240331 cache_miss:" in messages
    assert "[PROFILE] 72030 20240331 cache_hit:" in messages
    assert "download=" in messages
    assert "cache_read=" in messages
    assert "parse=" in messages
    assert "cache_write=" in messages


@pytest.mark.asyncio
async def test_get_annual_docs_filters_half_docs_from_persistent_cache(tmp_path) -> None:
    code = "65010"
    cache_manager = CacheManager(cache_dir=str(tmp_path))
    cached_docs = [
        {
            "docID": "S100HALF",
            "docTypeCode": "160",
            "period_type": "2Q",
            "edinet_fy_end": "2025-03-31",
        },
        {
            "docID": "S100ANNUAL",
            "docTypeCode": "120",
            "period_type": "FY",
            "edinet_fy_end": "2025-03-31",
        },
        {
            "docID": "S100AMEND",
            "docTypeCode": "130",
            "period_type": "FY",
            "edinet_fy_end": "2025-03-31",
            "_is_amendment": True,
        },
    ]
    cache_manager.set(
        f"edinet_docs_{code}",
        {"_cache_version": __version__, "docs": cached_docs},
    )
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client, cache_manager=cache_manager)

    docs = await fetcher._get_annual_docs(code, [], 1)

    assert [doc["docID"] for doc in docs] == ["S100ANNUAL", "S100AMEND"]


@pytest.mark.asyncio
async def test_get_annual_docs_saves_to_persistent_cache_after_api_call(tmp_path) -> None:
    code = "72030"
    cache_manager = CacheManager(cache_dir=str(tmp_path))
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client, cache_manager=cache_manager)
    fetcher._search_edinet_annual_docs = AsyncMock(return_value=([{"docID": "S100TEST"}], []))  # type: ignore[method-assign]

    docs = await fetcher._get_annual_docs(
        code,
        [_financial_record("2023-04-01", "2024-03-31", "2024-06-01")],
        1,
    )
    # キャッシュキーは max_years 非依存の固定キー
    cached = cache_manager.get("edinet_docs_72030")
    assert docs == [{"docID": "S100TEST"}]
    assert isinstance(cached, dict)
    assert cached["docs"] == [{"docID": "S100TEST"}]


@pytest.mark.asyncio
async def test_get_annual_docs_ignores_q2_records_for_year_selection() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._search_edinet_annual_docs = AsyncMock(return_value=([{"docID": "S100ANNUAL"}], []))  # type: ignore[method-assign]

    docs = await fetcher._get_annual_docs(
        "59320",
        [
            _financial_record("2025-06-01", "2026-05-31", "2026-01-08", period_type="2Q"),
            _financial_record("2024-06-01", "2025-05-31", "2025-07-10"),
            _financial_record("2023-06-01", "2024-05-31", "2024-07-11"),
            _financial_record("2022-06-01", "2023-05-31", "2023-07-12"),
            _financial_record("2021-06-01", "2022-05-31", "2022-07-12"),
            _financial_record("2020-06-01", "2021-05-31", "2021-07-13"),
        ],
        5,
    )

    assert docs == [{"docID": "S100ANNUAL"}]
    # save_count = max(10, 5) = 10
    fetcher._search_edinet_annual_docs.assert_awaited_once_with("59320", 10, known_not_found_fy_ends=frozenset())


@pytest.mark.asyncio
async def test_get_annual_docs_reuses_xbrl_record_doc_ids() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)

    docs = await fetcher._get_annual_docs(
        "72030",
        [{
            "CurPerType": "FY",
            "CurFYEn": "2024-03-31",
            "DiscDate": "2024-06-01",
            "_docID": "S100ANNUAL",
        }],
        1,
    )

    assert docs == [{
        "docID": "S100ANNUAL",
        "edinet_fy_end": "2024-03-31",
        "period_type": "FY",
        "submitDateTime": "2024-06-01",
    }]


@pytest.mark.asyncio
async def test_doc_id_maps_split_primary_and_amendment_doc_ids() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    docs = [
        {
            "docID": "S100W56G",
            "docTypeCode": "120",
            "edinet_fy_end": "2025-03-31",
        },
        {
            "docID": "S100WFSJ",
            "docTypeCode": "130",
            "edinet_fy_end": "2025-03-31",
            "_is_amendment": True,
            "parentDocID": "S100W56G",
        },
    ]
    fetcher._get_annual_docs = AsyncMock(return_value=docs)  # type: ignore[method-assign]

    doc_ids = await fetcher.get_doc_ids_by_year("65010", [], 1)
    amendment_doc_ids = await fetcher.get_amendment_doc_ids_by_year("65010", [], 1)

    assert doc_ids == {"20250331": "S100W56G"}
    assert amendment_doc_ids == {"20250331": "S100WFSJ"}


@pytest.mark.asyncio
async def test_get_half_year_docs_reads_from_persistent_cache(tmp_path) -> None:
    code = "72030"
    max_years = 1
    cache_manager = CacheManager(cache_dir=str(tmp_path))
    cache_manager.set(
        f"edinet_docs_{code}_2Q",
        {
            "_cache_version": __version__,
            "docs": [{"docID": "S100HALFCACHED"}],
        },
    )
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client, cache_manager=cache_manager)
    financial_data = [
        _financial_record("2023-04-01", "2024-03-31", "2023-11-10", period_type="2Q"),
    ]

    docs = await fetcher._get_half_year_docs(code, financial_data, max_years)

    assert docs == [{"docID": "S100HALFCACHED"}]


@pytest.mark.asyncio
async def test_get_half_year_docs_reuses_xbrl_record_doc_ids() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)

    docs = await fetcher._get_half_year_docs(
        "72030",
        [{
            "CurPerType": "2Q",
            "CurFYEn": "2024-03-31",
            "CurPerSt": "2023-04-01",
            "CurPerEn": "2023-09-30",
            "DiscDate": "2023-11-10",
            "_docID": "S100HALF",
        }],
        1,
    )

    assert docs == [{
        "docID": "S100HALF",
        "edinet_fy_end": "2024-03-31",
        "period_type": "2Q",
        "submitDateTime": "2023-11-10",
        "edinet_period_start": "2023-04-01",
        "periodStart": "2023-04-01",
        "edinet_period_end": "2023-09-30",
        "periodEnd": "2023-09-30",
    }]


@pytest.mark.asyncio
async def test_get_half_year_docs_returns_empty_when_no_q2_records() -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._search_edinet_half_docs = AsyncMock(return_value=[])  # type: ignore[method-assign]

    docs = await fetcher._get_half_year_docs(
        "72030",
        [
            _financial_record("2023-04-01", "2024-03-31", "2024-06-01", period_type="FY"),
            _financial_record("2022-04-01", "2023-03-31", "2023-06-01", period_type="3Q"),
        ],
        2,
    )

    assert docs == []
    # save_count = max(10, 2) = 10
    fetcher._search_edinet_half_docs.assert_awaited_once_with("72030", 10)


@pytest.mark.asyncio
async def test_build_xbrl_half_year_records_builds_2q_record(monkeypatch) -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._download_and_parse_docs = AsyncMock(return_value={"20250331": (Path("."), {}, {})})  # type: ignore[method-assign]

    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_is_compat",
        lambda *args, **kwargs: {
            "sales": 50_000_000,
            "operating_profit": 6_000_000,
            "net_profit": 4_000_000,
            "accounting_standard": "J-GAAP",
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_bs_compat",
        lambda *args, **kwargs: {"net_assets": 40_000_000},
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_cf_compat",
        lambda *args, **kwargs: {
            "cfo": {"current": 7_000_000},
            "cfi": {"current": -2_000_000},
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder.extract_shareholder_metrics",
        lambda *args, **kwargs: {
            "EPS": 40.0,
            "BPS": 400.0,
            "ShOutFY": 120_000.0,
            "DivTotalAnn": None,
            "PayoutRatioAnn": None,
            "CashEq": 9_000_000,
            "DivAnn": None,
            "Div2Q": 25.0,
        },
    )

    records = await fetcher.build_xbrl_half_year_records(
        "72030",
        1,
        docs=[{
            "docID": "S100HALF",
            "edinet_fy_end": "2025-03-31",
            "edinet_period_start": "2024-04-01",
            "edinet_period_end": "2024-09-30",
            "submitDateTime": "2024-11-14T10:00:00",
        }],
    )

    assert records == [{
        "Code": "72030",
        "CurFYEn": "2025-03-31",
        "CurFYSt": "2024-04-01",
        "CurPerSt": "2024-04-01",
        "CurPerEn": "2024-09-30",
        "CurPerType": "2Q",
        "DiscDate": "2024-11-14",
        "Sales": 50_000_000,
        "SalesLabel": "売上高",
        "OP": 6_000_000,
        "NP": 4_000_000,
        "NetAssets": 40_000_000,
        "CFO": 7_000_000,
        "CFI": -2_000_000,
        "EPS": 40.0,
        "BPS": 400.0,
        "ShOutFY": 120_000.0,
        "DivTotalAnn": None,
        "PayoutRatioAnn": None,
        "CashEq": 9_000_000,
        "DivAnn": None,
        "Div2Q": 25.0,
        "_xbrl_source": True,
        "_accounting_standard": "J-GAAP",
        "_docID": "S100HALF",
    }]


@pytest.mark.asyncio
async def test_build_xbrl_annual_records_falls_back_to_ordinary_revenue_for_sales(monkeypatch) -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._download_and_parse_docs = AsyncMock(return_value={"20250331": (Path("."), {}, {})})  # type: ignore[method-assign]

    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_is_compat",
        lambda *args, **kwargs: {
            "sales": None,
            "operating_profit": 367_694_000_000,
            "net_profit": 257_635_000_000,
            "accounting_standard": "J-GAAP",
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_gp_compat",
        lambda *args, **kwargs: {"current_sales": 2_922_428_000_000},
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_bs_compat",
        lambda *args, **kwargs: {"net_assets": 3_127_317_000_000},
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_cf_compat",
        lambda *args, **kwargs: {
            "cfo": {"current": 3_976_669_000_000},
            "cfi": {"current": -1_763_839_000_000},
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder.extract_shareholder_metrics",
        lambda *args, **kwargs: {},
    )

    records = await fetcher.build_xbrl_annual_records(
        "83090",
        1,
        docs=[
            {
                "docID": "S100VXKF",
                "edinet_fy_end": "2025-03-31",
                "submitDateTime": "2025-06-25T10:00:00",
            }
        ],
    )

    assert records[0]["Sales"] == 2_922_428_000_000
    assert records[0]["SalesLabel"] == "経常収益"
    assert records[0]["OP"] == 367_694_000_000


@pytest.mark.asyncio
async def test_build_xbrl_annual_records_uses_operating_profit_fallback(monkeypatch) -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._download_and_parse_docs = AsyncMock(return_value={"20250331": (Path("."), {}, {})})  # type: ignore[method-assign]

    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_is_compat",
        lambda *args, **kwargs: {
            "sales": 3_195_828_000_000,
            "operating_profit": None,
            "net_profit": 260_951_000_000,
            "accounting_standard": "US-GAAP",
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_op_compat",
        lambda *args, **kwargs: {"current": 340_594_000_000},
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_bs_compat",
        lambda *args, **kwargs: {"net_assets": 3_348_480_000_000},
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_cf_compat",
        lambda *args, **kwargs: {
            "cfo": {"current": 428_162_000_000},
            "cfi": {"current": -541_953_000_000},
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder.extract_shareholder_metrics",
        lambda *args, **kwargs: {"CashEq": 172_111_000_000},
    )

    records = await fetcher.build_xbrl_annual_records(
        "49010",
        1,
        docs=[
            {
                "docID": "S100W3XJ",
                "edinet_fy_end": "2025-03-31",
                "submitDateTime": "2025-06-27T10:00:00",
            }
        ],
    )

    assert records[0]["OP"] == 340_594_000_000
    assert records[0]["CashEq"] == 172_111_000_000


@pytest.mark.asyncio
async def test_build_xbrl_annual_records_defers_ordinary_income_to_edinet_applier(monkeypatch) -> None:
    edinet_client = Mock()
    edinet_client.api_key = "dummy"
    fetcher = EdinetFetcher(edinet_client=edinet_client)
    fetcher._download_and_parse_docs = AsyncMock(return_value={"20250331": (Path("."), {}, {})})  # type: ignore[method-assign]

    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_is_compat",
        lambda *args, **kwargs: {
            "sales": 13_629_997_000_000,
            "operating_profit": None,
            "net_profit": 1_862_946_000_000,
            "accounting_standard": "J-GAAP",
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_op_compat",
        lambda *args, **kwargs: {"current": 2_669_483_000_000, "label": "経常利益"},
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_bs_compat",
        lambda *args, **kwargs: {"net_assets": 21_728_132_000_000},
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder._extract_cf_compat",
        lambda *args, **kwargs: {
            "cfo": {"current": 6_415_000_000},
            "cfi": {"current": -186_948_000_000},
        },
    )
    monkeypatch.setattr(
        "blue_ticker.services._xbrl_record_builder.extract_shareholder_metrics",
        lambda *args, **kwargs: {},
    )

    records = await fetcher.build_xbrl_annual_records(
        "83060",
        1,
        docs=[
            {
                "docID": "S100W4FB",
                "edinet_fy_end": "2025-03-31",
                "submitDateTime": "2025-06-25T10:00:00",
            }
        ],
    )

    assert records[0]["OP"] is None


def test_prepare_q2_records_deduplicates_by_fy_end_keeping_latest_disc_date() -> None:
    fetcher = EdinetFetcher(edinet_client=Mock())

    records = fetcher._prepare_q2_records(
        [
            _financial_record("2023-04-01", "2024-03-31", "2023-11-05", period_type="2Q"),
            _financial_record("2023-04-01", "2024-03-31", "2023-11-10", period_type="2Q"),
            _financial_record("2022-04-01", "2023-03-31", "2022-11-10", period_type="2Q"),
        ],
        3,
    )

    assert len(records) == 2
    assert records[0]["CurFYEn"] == "2024-03-31"
    assert records[0]["DiscDate"] == "2023-11-10"
