import asyncio

import pytest

from blue_ticker.services.analyzer import IndividualAnalyzer


class _ConcurrentEdinetFetcher:
    def __init__(self) -> None:
        self.predownload_started = asyncio.Event()
        self.fetch_started = asyncio.Event()
        self.extract_pre_parsed_map: dict | None = None
        self.fetch_max_documents: int | None = None

    async def build_xbrl_annual_records(self, code: str, max_years: int) -> list[dict]:
        return [{
            "CurPerType": "FY",
            "CurFYEn": "2024-03-31",
            "CurFYSt": "2023-04-01",
            "DiscDate": "2024-06-01",
            "Sales": 1_000_000_000,
            "OP": 100_000_000,
            "NP": 80_000_000,
            "NetAssets": 500_000_000,
            "_xbrl_source": True,
        }]

    async def predownload_and_parse(self, code: str, financial_data: list[dict], actual_years: int) -> dict:
        self.predownload_started.set()
        await asyncio.wait_for(self.fetch_started.wait(), timeout=1.0)
        return {"20240331": {"elements": []}}

    async def fetch_edinet_data_async(
        self,
        code: str,
        financial_data: list[dict],
        max_documents: int = 10,
    ) -> dict:
        self.fetch_max_documents = max_documents
        await asyncio.wait_for(self.predownload_started.wait(), timeout=1.0)
        self.fetch_started.set()
        return {"documents": [{"docID": "S100TEST"}]}

    async def extract_all_by_year(
        self,
        code: str,
        financial_data: list[dict],
        actual_years: int,
        docs: list[dict] | None = None,
        pre_parsed_map: dict | None = None,
    ) -> dict:
        self.extract_pre_parsed_map = pre_parsed_map
        return {
            "gp": {"20240331": {"current": 400_000_000, "method": "direct"}},
            "doc_ids": {"20240331": "S100TEST"},
        }


class _FailingEdinetFetcher:
    async def build_xbrl_annual_records(self, *args, **kwargs) -> list:
        raise AssertionError("EDINET annual record fallback should not be called with annual_data")

    async def predownload_and_parse(self, *args, **kwargs) -> dict:
        raise AssertionError("EDINET predownload should not be called without financial_data")

    async def fetch_edinet_data_async(self, *args, **kwargs) -> dict:
        raise AssertionError("EDINET metadata fetch should not be called without financial_data")

    async def extract_all_by_year(self, *args, **kwargs) -> dict:
        raise AssertionError("EDINET metric extraction should not be called without financial_data")


class _EdinetOnlyFetcher:
    def __init__(self) -> None:
        self.build_args: tuple | None = None
        self.predownload_financial_data: list[dict] | None = None
        self.fetch_financial_data: list[dict] | None = None

    async def build_xbrl_annual_context(self, *args, **kwargs) -> dict:
        self.build_args = (args, kwargs)
        return {
            "docs": [{"docID": "S100TEST"}],
            "pre_parsed_map": {},
            "records": [
                {
                    "Code": "7203",
                    "CurPerType": "FY",
                    "CurFYSt": "2023-04-01",
                    "CurFYEn": "2024-03-31",
                    "DiscDate": "2024-06-24",
                    "Sales": 1_000_000_000,
                    "OP": 100_000_000,
                    "NP": 80_000_000,
                    "NetAssets": 500_000_000,
                    "_xbrl_source": True,
                }
            ],
        }

    async def predownload_and_parse(self, code: str, financial_data: list[dict], actual_years: int) -> dict:
        self.predownload_financial_data = financial_data
        return {}

    async def fetch_edinet_data_async(
        self,
        code: str,
        financial_data: list[dict],
        max_documents: int = 10,
    ) -> dict:
        self.fetch_financial_data = financial_data
        return {}

    async def extract_all_by_year(
        self,
        code: str,
        financial_data: list[dict],
        actual_years: int,
        docs: list[dict] | None = None,
        pre_parsed_map: dict | None = None,
    ) -> dict:
        return {"doc_ids": {}}


class _ContextEdinetOnlyFetcher:
    def __init__(self) -> None:
        self.fetch_financial_data: list[dict] | None = None
        self.extract_docs: list[dict] | None = None
        self.extract_pre_parsed_map: dict | None = None
        self.predownload_called = False

    async def build_xbrl_annual_context(self, *args, **kwargs) -> dict:
        return {
            "docs": [{"docID": "S100CTX"}],
            "pre_parsed_map": {"20240331": {"elements": []}},
            "records": [
                {
                    "Code": "7203",
                    "CurPerType": "FY",
                    "CurFYSt": "2023-04-01",
                    "CurFYEn": "2024-03-31",
                    "DiscDate": "2024-06-24",
                    "Sales": 1_000_000_000,
                    "OP": 100_000_000,
                    "NP": 80_000_000,
                    "NetAssets": 500_000_000,
                    "_xbrl_source": True,
                }
            ],
        }

    async def predownload_and_parse(self, *args, **kwargs) -> dict:
        self.predownload_called = True
        return {}

    async def fetch_edinet_data_async(
        self,
        code: str,
        financial_data: list[dict],
        max_documents: int = 10,
    ) -> dict:
        self.fetch_financial_data = financial_data
        return {}

    async def extract_all_by_year(
        self,
        code: str,
        financial_data: list[dict],
        actual_years: int,
        docs: list[dict] | None = None,
        pre_parsed_map: dict | None = None,
    ) -> dict:
        self.extract_docs = docs
        self.extract_pre_parsed_map = pre_parsed_map
        return {"doc_ids": {}}


def _make_analyzer(financial_data: list[dict], edinet_fetcher: object) -> IndividualAnalyzer:
    analyzer = IndividualAnalyzer(edinet_client=None)
    analyzer._edinet_fetcher = edinet_fetcher  # type: ignore[assignment]
    return analyzer


@pytest.mark.asyncio
async def test_fetch_analysis_data_fetches_edinet_metadata_in_parallel_with_predownload() -> None:
    edinet_fetcher = _ConcurrentEdinetFetcher()
    analyzer = _make_analyzer([{"DisclosedDate": "2024-06-01"}], edinet_fetcher)
    financial_data = [{
        "CurPerType": "FY",
        "CurFYEn": "2024-03-31",
        "CurFYSt": "2023-04-01",
        "DiscDate": "2024-06-01",
        "Sales": 1_000_000_000,
        "OP": 100_000_000,
        "NP": 80_000_000,
        "NetAssets": 500_000_000,
    }]

    result = await analyzer.fetch_analysis_data(
        "7203",
        analysis_years=1,
        max_documents=3,
        prefetched_stock_info={"Code": "7203"},
        prefetched_financial_data=financial_data,
    )

    assert result["edinet_data"] == {"documents": [{"docID": "S100TEST"}]}
    assert edinet_fetcher.fetch_max_documents == 3
    assert edinet_fetcher.extract_pre_parsed_map == {"20240331": {"elements": []}}
    assert result["metrics"]["years"][0]["CalculatedData"]["GrossProfit"] == pytest.approx(400.0)
    assert result["metrics"]["years"][0]["CalculatedData"]["DocID"] == "S100TEST"


@pytest.mark.asyncio
async def test_fetch_analysis_data_uses_edinet_annual_records_without_prefetched_data() -> None:
    edinet_fetcher = _EdinetOnlyFetcher()
    analyzer = IndividualAnalyzer(edinet_client=None)
    analyzer._edinet_fetcher = edinet_fetcher  # type: ignore[assignment]

    result = await analyzer.fetch_analysis_data("7203", analysis_years=1)

    assert result["edinet_data"] == {}
    assert result["metrics"]["analysis_years"] == 1
    assert result["annual_data"][0]["_xbrl_source"] is True
    assert edinet_fetcher.predownload_financial_data is None
    assert edinet_fetcher.fetch_financial_data == result["annual_data"]


@pytest.mark.asyncio
async def test_fetch_analysis_data_reuses_annual_context_preparsed_map() -> None:
    edinet_fetcher = _ContextEdinetOnlyFetcher()
    analyzer = IndividualAnalyzer(edinet_client=None)
    analyzer._edinet_fetcher = edinet_fetcher  # type: ignore[assignment]

    result = await analyzer.fetch_analysis_data("7203", analysis_years=1)

    assert result["annual_data"][0]["_xbrl_source"] is True
    assert edinet_fetcher.predownload_called is False
    assert edinet_fetcher.fetch_financial_data == result["annual_data"]
    assert edinet_fetcher.extract_docs == [{"docID": "S100CTX"}]
    assert edinet_fetcher.extract_pre_parsed_map == {"20240331": {"elements": []}}
