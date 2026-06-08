"""
DataService のユニットテスト

EdinetAPIClient / IndividualAnalyzer をモック化し、
キャッシュロジック・データ変換などのビジネスロジックを検証する。
"""
import pytest
from unittest.mock import AsyncMock, patch


# ──────────────────────────────────────────────────────────────
# フィクスチャ
# ──────────────────────────────────────────────────────────────

@pytest.fixture
def svc(tmp_path):
    """
    DataService を外部依存ゼロで構築する。
    - settings_store は tmp_path を向くスタブ
    - EdinetAPIClient は AsyncMock
    - CacheManager は tmp_path に実ファイルを作成（TTL ロジックも動作確認できる）
    """
    with (
        patch("blue_ticker.services.data_service.settings_store") as mock_settings,
        patch("blue_ticker.services.data_service.EdinetAPIClient"),
    ):
        mock_settings.edinet_api_key = ""
        mock_settings.cache_dir = str(tmp_path)
        mock_settings.cache_enabled = True

        from blue_ticker.services.data_service import DataService
        ds = DataService()
        ds.edinet_client = AsyncMock()
        yield ds


# ──────────────────────────────────────────────────────────────
# search_companies
# ──────────────────────────────────────────────────────────────

class TestSearchCompanies:
    @pytest.mark.asyncio
    async def test_delegates_to_master_data(self, svc):
        expected = [{"code": "72030", "name": "トヨタ自動車"}]
        with patch("blue_ticker.services.company_info_service.master_data_manager") as mm:
            mm.search.return_value = expected
            result = await svc.search_companies("トヨタ")
        mm.search.assert_called_once_with("トヨタ", limit=50)
        assert result == expected

    @pytest.mark.asyncio
    async def test_empty_query_returns_results(self, svc):
        with patch("blue_ticker.services.company_info_service.master_data_manager") as mm:
            mm.search.return_value = []
            result = await svc.search_companies("")
        assert result == []


# ──────────────────────────────────────────────────────────────
# fetch_stock_basic_info
# ──────────────────────────────────────────────────────────────

class TestFetchStockBasicInfo:
    def test_found_returns_mapped_fields(self, svc):
        stock = {
            "CoName": "トヨタ自動車",
            "CoNameEn": "Toyota Motor",
            "S33Nm": "輸送用機器",
            "S33": "33",
            "S17": "17",
            "S17Nm": "自動車・輸送機",
            "MktNm": "プライム",
        }
        with patch("blue_ticker.services.company_info_service.master_data_manager") as mm:
            mm.get_by_code.return_value = stock
            info = svc.fetch_stock_basic_info("72030")
        assert info["name"] == "トヨタ自動車"
        assert info["industry"] == "輸送用機器"
        assert info["code"] == "72030"

    def test_not_found_returns_empty_defaults(self, svc):
        with patch("blue_ticker.services.company_info_service.master_data_manager") as mm:
            mm.get_by_code.return_value = None
            info = svc.fetch_stock_basic_info("99990")
        assert info["name"] == ""
        assert info["industry"] == ""
        assert info["code"] == "99990"


# ──────────────────────────────────────────────────────────────
# get_raw_analysis_data (キャッシュ ヒット / ミス)
# ──────────────────────────────────────────────────────────────

class TestGetRawAnalysisData:
    def _make_cached(self, code: str) -> dict:
        from blue_ticker import __version__
        cache_version = __version__
        return {
            "_cache_version": cache_version,
            "code": code,
            "name": "トヨタ自動車",
            "metrics": {"years": []},
            "edinet_data": {},
            "analyzed_at": "2024-01-01T00:00:00",
        }

    def _make_cached_with_years(self, code: str, count: int) -> dict:
        cached = self._make_cached(code)
        cached["metrics"] = {
            "analysis_years": count,
            "available_years": count,
            "years": [
                {
                    "fy_end": f"{2024 - idx}-03-31",
                    "CalculatedData": {
                        "DocID": f"S100XXXX{idx:02d}",
                        "Sales": float(100 - idx),
                        "InterestBearingDebt": float(50 - idx),
                        "CurrentAssets": float(200 - idx),
                        "NonCurrentAssets": float(300 - idx),
                        "CurrentLiabilities": float(50 - idx),
                        "NonCurrentLiabilities": float(60 - idx),
                        "NetAssets": float(390 - idx),
                    },
                }
                for idx in range(count)
            ],
        }
        return cached

    @pytest.mark.asyncio
    async def test_cache_hit_skips_fetch(self, svc):
        cached = self._make_cached("72030")
        svc.cache_manager.set("individual_analysis_72030", cached)

        mock_analyzer = AsyncMock()
        with patch.object(svc, "get_analyzer", return_value=mock_analyzer):
            result = await svc.get_raw_analysis_data("72030", use_cache=True)

        mock_analyzer.fetch_analysis_data.assert_not_called()
        assert result["code"] == "72030"
        assert "_cache_version" not in result

    @pytest.mark.asyncio
    async def test_cache_hit_trims_to_requested_years(self, svc):
        cached = self._make_cached_with_years("72030", 5)
        svc.cache_manager.set("individual_analysis_72030", cached)

        mock_analyzer = AsyncMock()
        with patch.object(svc, "get_analyzer", return_value=mock_analyzer):
            result = await svc.get_raw_analysis_data("72030", use_cache=True, analysis_years=3)

        mock_analyzer.fetch_analysis_data.assert_not_called()
        assert len(result["metrics"]["years"]) == 3
        assert result["metrics"]["analysis_years"] == 3
        assert result["metrics"]["available_years"] == 3
        assert result["metrics"]["years"][-1]["fy_end"] == "2022-03-31"

    @pytest.mark.asyncio
    async def test_cache_with_too_few_years_calls_analyzer(self, svc):
        cached = self._make_cached_with_years("72030", 3)
        svc.cache_manager.set("individual_analysis_72030", cached)

        mock_analyzer = AsyncMock()
        mock_analyzer.fetch_analysis_data.return_value = {
            "metrics": {
                "analysis_years": 5,
                "available_years": 5,
                "years": [
                    {"fy_end": f"{2024 - idx}-03-31", "CalculatedData": {"Sales": float(100 - idx)}}
                    for idx in range(5)
                ],
            },
            "edinet_data": {},
        }
        with (
            patch.object(svc, "get_analyzer", return_value=mock_analyzer),
            patch.object(svc, "fetch_stock_basic_info", return_value={"name": "トヨタ"}),
        ):
            result = await svc.get_raw_analysis_data("72030", use_cache=True, analysis_years=5)

        mock_analyzer.fetch_analysis_data.assert_called_once()
        assert len(result["metrics"]["years"]) == 5

    @pytest.mark.asyncio
    async def test_cache_miss_calls_analyzer(self, svc):
        mock_analyzer = AsyncMock()
        mock_analyzer.fetch_analysis_data.return_value = {
            "metrics": {"years": []},
            "edinet_data": {},
        }
        with (
            patch.object(svc, "get_analyzer", return_value=mock_analyzer),
            patch.object(svc, "fetch_stock_basic_info", return_value={"name": "トヨタ"}),
        ):
            result = await svc.get_raw_analysis_data("72030", use_cache=False)

        mock_analyzer.fetch_analysis_data.assert_called_once()
        assert result["code"] == "72030"

    @pytest.mark.asyncio
    async def test_cache_version_mismatch_calls_analyzer(self, svc):
        stale = self._make_cached("72030")
        stale["_cache_version"] = "0.0"
        svc.cache_manager.set("individual_analysis_72030", stale)

        mock_analyzer = AsyncMock()
        mock_analyzer.fetch_analysis_data.return_value = {
            "metrics": {"years": []},
            "edinet_data": {},
        }
        with (
            patch.object(svc, "get_analyzer", return_value=mock_analyzer),
            patch.object(svc, "fetch_stock_basic_info", return_value={"name": "トヨタ"}),
        ):
            await svc.get_raw_analysis_data("72030", use_cache=True)

        mock_analyzer.fetch_analysis_data.assert_called_once()

    @pytest.mark.asyncio
    async def test_incomplete_edinet_cache_calls_analyzer(self, svc):
        cached = self._make_cached("72030")
        cached["metrics"] = {
            "years": [
                {
                    "fy_end": "2024-03-31",
                    "CalculatedData": {
                        "DocID": "S100TEST",
                        "NP": 100.0,
                        "NetAssets": 1000.0,
                    },
                }
            ]
        }
        svc.cache_manager.set("individual_analysis_72030", cached)

        mock_analyzer = AsyncMock()
        mock_analyzer.fetch_analysis_data.return_value = {
            "metrics": {"years": []},
            "edinet_data": {},
        }
        with (
            patch.object(svc, "get_analyzer", return_value=mock_analyzer),
            patch.object(svc, "fetch_stock_basic_info", return_value={"name": "トヨタ"}),
        ):
            await svc.get_raw_analysis_data("72030", use_cache=True)

        mock_analyzer.fetch_analysis_data.assert_called_once()

    @pytest.mark.asyncio
    async def test_complete_edinet_cache_skips_fetch(self, svc):
        cached = self._make_cached("72030")
        cached["metrics"] = {
            "years": [
                {
                    "fy_end": "2024-03-31",
                    "CalculatedData": {
                        "DocID": "S100TEST",
                        "InterestBearingDebt": 500.0,
                        "ROIC": 10.0,
                        "CurrentAssets": 1000.0,
                        "NonCurrentAssets": 2000.0,
                        "CurrentLiabilities": 700.0,
                        "NonCurrentLiabilities": 800.0,
                        "NetAssets": 1500.0,
                    },
                }
            ]
        }
        svc.cache_manager.set("individual_analysis_72030", cached)

        mock_analyzer = AsyncMock()
        with patch.object(svc, "get_analyzer", return_value=mock_analyzer):
            result = await svc.get_raw_analysis_data("72030", use_cache=True)

        mock_analyzer.fetch_analysis_data.assert_not_called()
        assert result["metrics"]["years"][0]["CalculatedData"]["ROIC"] == 10.0

    @pytest.mark.asyncio
    async def test_analyzer_returns_empty_yields_empty(self, svc):
        mock_analyzer = AsyncMock()
        mock_analyzer.fetch_analysis_data.return_value = {}
        with patch.object(svc, "get_analyzer", return_value=mock_analyzer):
            result = await svc.get_raw_analysis_data("72030", use_cache=False)
        assert result == {}

    @pytest.mark.asyncio
    async def test_edinet_only_calls_analyzer_with_empty_prefetch(self, svc):
        """Analyzer側のEDINET-only構築へ進む。"""
        mock_analyzer = AsyncMock()
        mock_analyzer.fetch_analysis_data.return_value = {
            "metrics": {"years": []},
            "edinet_data": {},
        }
        with (
            patch.object(svc, "get_analyzer", return_value=mock_analyzer),
            patch.object(svc, "fetch_stock_basic_info", return_value={"name": ""}),
        ):
            result = await svc.get_raw_analysis_data("72030", use_cache=False)

        assert result["code"] == "72030"
        _, kwargs = mock_analyzer.fetch_analysis_data.call_args
        assert kwargs["prefetched_stock_info"] == {"Code": "72030", "name": ""}
        assert kwargs["prefetched_financial_data"] == []


# ──────────────────────────────────────────────────────────────
# extract_filing_content
# ──────────────────────────────────────────────────────────────

class TestExtractFilingContent:
    def _make_cached(self, code: str) -> dict:
        from blue_ticker import __version__
        cache_version = __version__
        return {
            "_cache_version": cache_version,
            "code": code,
            "metrics": {
                "years": [
                    {
                        "fy_end": "2024-03-31",
                        "CalculatedData": {"DocID": "S100NEW"},
                    },
                    {
                        "fy_end": "2023-03-31",
                        "CalculatedData": {"DocID": "S100OLD"},
                    },
                ],
            },
            "edinet_data": {},
        }

    @pytest.mark.asyncio
    async def test_uses_latest_doc_id_from_analysis_cache_when_doc_id_omitted(self, svc):
        svc.cache_manager.set("individual_analysis_72030", self._make_cached("72030"))
        svc.filing_service.extract_filing_content = AsyncMock(return_value={"doc_id": "S100NEW", "sections": {}})

        result = await svc.extract_filing_content("72030", sections=["mda"])

        assert result["doc_id"] == "S100NEW"
        svc.filing_service.extract_filing_content.assert_awaited_once_with(
            code="72030",
            doc_id="S100NEW",
            sections=["mda"],
        )

    @pytest.mark.asyncio
    async def test_explicit_doc_id_overrides_analysis_cache(self, svc):
        svc.cache_manager.set("individual_analysis_72030", self._make_cached("72030"))
        svc.filing_service.extract_filing_content = AsyncMock(return_value={"doc_id": "S100EXPLICIT", "sections": {}})

        result = await svc.extract_filing_content("72030", doc_id="S100EXPLICIT")

        assert result["doc_id"] == "S100EXPLICIT"
        svc.filing_service.extract_filing_content.assert_awaited_once_with(
            code="72030",
            doc_id="S100EXPLICIT",
            sections=None,
        )

    @pytest.mark.asyncio
    async def test_ignores_version_mismatched_analysis_cache(self, svc):
        cached = self._make_cached("72030")
        cached["_cache_version"] = "0.0"
        svc.cache_manager.set("individual_analysis_72030", cached)
        svc.filing_service.extract_filing_content = AsyncMock(return_value={"doc_id": "S100SEARCH", "sections": {}})

        await svc.extract_filing_content("72030")

        svc.filing_service.extract_filing_content.assert_awaited_once_with(
            code="72030",
            doc_id=None,
            sections=None,
        )

    @pytest.mark.asyncio
    async def test_falls_back_to_search_when_cached_doc_id_fails(self, svc):
        svc.cache_manager.set("individual_analysis_72030", self._make_cached("72030"))
        svc.filing_service.extract_filing_content = AsyncMock(
            side_effect=[
                ValueError("Document not found or download failed"),
                {"doc_id": "S100SEARCH", "sections": {}},
            ]
        )

        result = await svc.extract_filing_content("72030")

        assert result["doc_id"] == "S100SEARCH"
        assert svc.filing_service.extract_filing_content.await_args_list[0].kwargs == {
            "code": "72030",
            "doc_id": "S100NEW",
            "sections": None,
        }
        assert svc.filing_service.extract_filing_content.await_args_list[1].kwargs == {
            "code": "72030",
            "doc_id": None,
            "sections": None,
        }


# ──────────────────────────────────────────────────────────────
# HalfYearDataService
# ──────────────────────────────────────────────────────────────

class TestHalfYearRoic:
    def test_roic_uses_nopat_with_fallback_tax_rate(self):
        from blue_ticker.constants.financial import NOPAT_FALLBACK_TAX_RATE, PERCENT
        from blue_ticker.services.half_year_data_service import _apply_nopat_and_roic

        data = {"OP": 100.0, "NP": 999.0}

        _apply_nopat_and_roic(data, net_assets_m=800.0, ibd_m=200.0)

        expected_nopat = 100.0 * (1 - NOPAT_FALLBACK_TAX_RATE)
        assert data["NOPAT"] == pytest.approx(expected_nopat)
        invested_capital = 800.0 + 200.0
        assert data["ROIC"] == pytest.approx(expected_nopat / invested_capital * PERCENT)
        assert data["MetricSources"]["ROIC"]["method"] == "NOPAT / (NetAssets + InterestBearingDebt)"

    def test_roic_uses_nopat_with_effective_tax_rate(self):
        from blue_ticker.constants.financial import PERCENT
        from blue_ticker.services.half_year_data_service import _apply_nopat_and_roic

        data = {"OP": 100.0, "EffectiveTaxRate": 30.0}

        _apply_nopat_and_roic(data, net_assets_m=800.0, ibd_m=200.0)

        expected_nopat = 70.0
        assert data["NOPAT"] == pytest.approx(expected_nopat)
        invested_capital = 800.0 + 200.0
        assert data["ROIC"] == pytest.approx(expected_nopat / invested_capital * PERCENT)
        assert data["MetricSources"]["NOPAT"]["method"] == "OP × (1 - income_tax / pretax_income)"


class TestHalfYearDataService:
    def _make_service(self, tmp_path):
        from blue_ticker.services.half_year_data_service import HalfYearDataService
        from blue_ticker.utils.cache import CacheManager

        edinet_client = AsyncMock()
        cache_manager = CacheManager(cache_dir=str(tmp_path), enabled=True)
        return HalfYearDataService(edinet_client, cache_manager)

    def _fy_record(self) -> dict:
        return {
            "CurPerType": "FY",
            "CurFYEn": "2024-03-31",
            "DiscDate": "2024-05-14",
            "Sales": 100_000_000,
            "OP": 10_000_000,
            "NP": 8_000_000,
            "CFO": 12_000_000,
            "CFI": -3_000_000,
            "NetAssets": 40_000_000,
        }

    def _q2_record(self) -> dict:
        return {
            "CurPerType": "2Q",
            "CurFYEn": "2024-03-31",
            "DiscDate": "2023-11-14",
            "Sales": 45_000_000,
            "OP": 4_000_000,
            "NP": 3_000_000,
            "CFO": 5_000_000,
            "CFI": -1_000_000,
            "NetAssets": 35_000_000,
        }

    @pytest.mark.asyncio
    async def test_cache_hit_skips_fetch(self, tmp_path):
        from blue_ticker import __version__
        cache_version = __version__
        service = self._make_service(tmp_path)
        # years 非依存キー。完結ペアが 1 組あれば trim(years=1) で返ってくる
        cached_periods = [
            {"label": "24H1", "half": "H1", "fy_end": "2024-03-31", "data": {"Sales": 45.0}},
            {"label": "24H2", "half": "H2", "fy_end": "2024-03-31", "data": {"Sales": 47.0}},
        ]
        service.cache_manager.set("half_year_periods_72030", {
            "_cache_version": cache_version,
            "periods": cached_periods,
        })

        result = await service.get_half_year_periods("72030", years=1, use_cache=True)

        assert result == cached_periods

    @pytest.mark.asyncio
    async def test_empty_financial_data_returns_empty(self, tmp_path):
        service = self._make_service(tmp_path)
        with patch("blue_ticker.services.half_year_data_service.EdinetFetcher") as fetcher_cls:
            fetcher = fetcher_cls.return_value
            fetcher.build_xbrl_annual_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": []})
            fetcher.build_xbrl_half_year_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": []})

            result = await service.get_half_year_periods("72030", years=3, use_cache=False)

        assert result == []

    @pytest.mark.asyncio
    async def test_empty_prefetch_uses_edinet_only_records(self, tmp_path):
        service = self._make_service(tmp_path)
        fy_record = self._fy_record()
        fy_record["CurFYEn"] = "2024-03-31"
        q2_record = self._q2_record()
        q2_record["CurFYEn"] = "2024-03-31"
        annual_docs = [{"docID": "S100FY"}]
        half_docs = [{"docID": "S100H1"}]
        annual_pre_parsed_map = {"20240331": ("fy-path", {}, {})}
        half_pre_parsed_map = {"20240331": ("h1-path", {}, {})}

        with patch("blue_ticker.services.half_year_data_service.EdinetFetcher") as fetcher_cls:
            fetcher = fetcher_cls.return_value
            fetcher.build_xbrl_annual_context = AsyncMock(return_value={"docs": annual_docs, "pre_parsed_map": annual_pre_parsed_map, "records": [fy_record]})
            fetcher.build_xbrl_half_year_context = AsyncMock(return_value={"docs": half_docs, "pre_parsed_map": half_pre_parsed_map, "records": [q2_record]})
            fetcher.extract_half_year_edinet_data = AsyncMock(return_value={})
            fetcher.extract_gross_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_ibd_by_year = AsyncMock(return_value={})
            fetcher.extract_operating_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_tax_expense_by_year = AsyncMock(return_value={})
            fetcher.extract_bs_by_year = AsyncMock(return_value={})

            result = await service.get_half_year_periods("72030", years=1, use_cache=False)

        assert [p["label"] for p in result] == ["24H1", "24H2"]
        assert result[0]["data"]["Sales"] == 45.0
        assert result[1]["data"]["Sales"] == 55.0
        # fetch_years = EDINET_DOC_DISCOVERY_LIMIT(10)
        fetcher.build_xbrl_annual_context.assert_awaited_once_with("72030", 10)
        fetcher.build_xbrl_half_year_context.assert_awaited_once_with("72030", 10)
        assert fetcher.extract_half_year_edinet_data.await_args is not None
        _, half_kwargs = fetcher.extract_half_year_edinet_data.await_args
        assert half_kwargs["docs"] == half_docs
        assert half_kwargs["pre_parsed_map"] == half_pre_parsed_map
        assert fetcher.extract_gross_profit_by_year.await_args is not None
        _, gp_kwargs = fetcher.extract_gross_profit_by_year.await_args
        assert gp_kwargs["docs"] == annual_docs
        assert gp_kwargs["pre_parsed_map"] == annual_pre_parsed_map
        assert fetcher.extract_ibd_by_year.await_args is not None
        _, ibd_kwargs = fetcher.extract_ibd_by_year.await_args
        assert ibd_kwargs["docs"] == annual_docs
        assert ibd_kwargs["pre_parsed_map"] == annual_pre_parsed_map
        assert fetcher.extract_operating_profit_by_year.await_args is not None
        _, op_kwargs = fetcher.extract_operating_profit_by_year.await_args
        assert op_kwargs["docs"] == annual_docs
        assert op_kwargs["pre_parsed_map"] == annual_pre_parsed_map

    @pytest.mark.asyncio
    async def test_edinet_failure_returns_base_periods(self, tmp_path):
        service = self._make_service(tmp_path)
        fy_record = self._fy_record()
        q2_record = self._q2_record()

        with patch("blue_ticker.services.half_year_data_service.EdinetFetcher") as fetcher_cls:
            fetcher = fetcher_cls.return_value
            fetcher.build_xbrl_annual_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": [fy_record]})
            fetcher.build_xbrl_half_year_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": [q2_record]})
            fetcher.extract_half_year_edinet_data = AsyncMock(side_effect=RuntimeError("edinet down"))
            fetcher.extract_gross_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_ibd_by_year = AsyncMock(return_value={})
            fetcher.extract_operating_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_tax_expense_by_year = AsyncMock(return_value={})
            fetcher.extract_bs_by_year = AsyncMock(return_value={})

            result = await service.get_half_year_periods("72030", years=1, use_cache=False)

        assert [p["label"] for p in result] == ["24H1", "24H2"]
        assert result[0]["data"]["Sales"] == 45.0
        assert result[0]["data"]["CFC"] == 4.0
        assert result[0]["data"]["FreeCF"] == result[0]["data"]["CFC"]
        assert result[1]["data"]["Sales"] == 55.0
        assert result[1]["data"]["CFC"] == 5.0
        assert result[1]["data"]["FreeCF"] == result[1]["data"]["CFC"]

    @pytest.mark.asyncio
    async def test_edinet_failure_excludes_debug_fields_by_default(self, tmp_path):
        service = self._make_service(tmp_path)
        fy_record = self._fy_record()
        q2_record = self._q2_record()

        with patch("blue_ticker.services.half_year_data_service.EdinetFetcher") as fetcher_cls:
            fetcher = fetcher_cls.return_value
            fetcher.build_xbrl_annual_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": [fy_record]})
            fetcher.build_xbrl_half_year_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": [q2_record]})
            fetcher.extract_half_year_edinet_data = AsyncMock(side_effect=RuntimeError("edinet down"))
            fetcher.extract_gross_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_ibd_by_year = AsyncMock(return_value={})
            fetcher.extract_operating_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_tax_expense_by_year = AsyncMock(return_value={})
            fetcher.extract_bs_by_year = AsyncMock(return_value={})

            result = await service.get_half_year_periods("72030", years=1, use_cache=False)

        for period in result:
            assert "MetricSources" not in period["data"]

    @pytest.mark.asyncio
    async def test_edinet_failure_includes_debug_fields_when_requested(self, tmp_path):
        service = self._make_service(tmp_path)
        fy_record = self._fy_record()
        q2_record = self._q2_record()

        with patch("blue_ticker.services.half_year_data_service.EdinetFetcher") as fetcher_cls:
            fetcher = fetcher_cls.return_value
            fetcher.build_xbrl_annual_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": [fy_record]})
            fetcher.build_xbrl_half_year_context = AsyncMock(return_value={"docs": [], "pre_parsed_map": {}, "records": [q2_record]})
            fetcher.extract_half_year_edinet_data = AsyncMock(side_effect=RuntimeError("edinet down"))
            fetcher.extract_gross_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_ibd_by_year = AsyncMock(return_value={})
            fetcher.extract_operating_profit_by_year = AsyncMock(return_value={})
            fetcher.extract_tax_expense_by_year = AsyncMock(return_value={})
            fetcher.extract_bs_by_year = AsyncMock(return_value={})

            result = await service.get_half_year_periods("72030", years=1, use_cache=False, include_debug_fields=True)

        assert "MetricSources" in result[0]["data"]
        assert result[0]["data"]["MetricSources"]["CFC"]["method"] == "CFO + CFI"


# ──────────────────────────────────────────────────────────────
# _has_incomplete_edinet_metrics
# ──────────────────────────────────────────────────────────────

class TestHasIncompleteEdinetMetrics:
    def _fn(self):
        from blue_ticker.services.data_service import _has_incomplete_edinet_metrics
        return _has_incomplete_edinet_metrics

    def _make_cached(self, **cd_fields) -> dict:
        return {
            "metrics": {
                "years": [{"CalculatedData": {"DocID": "S100XXXX", **cd_fields}}]
            }
        }

    def _complete_cd(self) -> dict:
        return {
            "DocID": "S100XXXX",
            "InterestBearingDebt": 200.0,
            "NOPAT": 80.0,
            "ROIC": 8.0,
            "CurrentAssets": 500.0,
            "NonCurrentAssets": 800.0,
            "CurrentLiabilities": 300.0,
            "NonCurrentLiabilities": 200.0,
            "NetAssets": 600.0,
        }

    def test_complete_cache_returns_false(self):
        fn = self._fn()
        assert fn({"metrics": {"years": [{"CalculatedData": self._complete_cd()}]}}) is False

    def test_missing_ibd_returns_true(self):
        fn = self._fn()
        cd = self._complete_cd()
        del cd["InterestBearingDebt"]
        assert fn({"metrics": {"years": [{"CalculatedData": cd}]}}) is True

    def test_nopat_present_roic_missing_returns_true(self):
        """NOPAT が揃っているのに ROIC が None → 不完全"""
        fn = self._fn()
        cd = self._complete_cd()
        cd["ROIC"] = None
        assert fn({"metrics": {"years": [{"CalculatedData": cd}]}}) is True

    def test_nopat_missing_roic_missing_returns_false(self):
        """OP 欠損で NOPAT も ROIC も None → ROIC 計算不可なので不完全扱いしない"""
        fn = self._fn()
        cd = self._complete_cd()
        del cd["NOPAT"]
        cd["ROIC"] = None
        assert fn({"metrics": {"years": [{"CalculatedData": cd}]}}) is False

    def test_no_doc_id_returns_incomplete(self):
        fn = self._fn()
        cd = {"InterestBearingDebt": None, "ROIC": None}  # DocID なし → 不完全
        assert fn({"metrics": {"years": [{"CalculatedData": cd}]}}) is True
