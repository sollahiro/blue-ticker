from pathlib import Path
from typing import Any

import pytest

from blue_ticker.services import edinet_smoke_cache
from blue_ticker.services.edinet_smoke_cache import (
    SmokeCompany,
    prepare_edinet_smoke_cache,
    smoke_companies_from_codes,
)


class _FakeClient:
    async def download_document(self, doc_id: str, doc_type: int = 1) -> Path | None:
        return Path("cache") / "edinet" / f"{doc_id}_xbrl"


def test_smoke_companies_from_codes_uses_defaults_when_omitted() -> None:
    companies = smoke_companies_from_codes(None)

    assert companies[0].code == "4901"
    assert any(company.code == "7269" for company in companies)


def test_smoke_companies_from_codes_allows_custom_codes() -> None:
    companies = smoke_companies_from_codes(["7203"])

    assert companies == (SmokeCompany("7203", "7203", "custom"),)


@pytest.mark.asyncio
async def test_prepare_edinet_smoke_cache_downloads_latest_annual_doc(monkeypatch) -> None:
    async def fake_build_document_index_for_code(*args: Any, **kwargs: Any) -> tuple[list[dict[str, Any]], list[str]]:
        return [
            {
                "docID": "OLD",
                "docTypeCode": "120",
                "edinet_fy_end": "2024-03-31",
                "submitDateTime": "2024-06-01 10:00",
            },
            {
                "docID": "NEW",
                "docTypeCode": "120",
                "edinet_fy_end": "2025-03-31",
                "submitDateTime": "2025-06-01 10:00",
            },
        ], []

    monkeypatch.setattr(
        edinet_smoke_cache,
        "build_document_index_for_code",
        fake_build_document_index_for_code,
    )

    summary = await prepare_edinet_smoke_cache(
        _FakeClient(),  # type: ignore[arg-type]
        (SmokeCompany("7203", "トヨタ", "custom"),),
    )

    assert summary.prepared == 1
    assert summary.entries[0].doc_id == "NEW"
    assert summary.entries[0].xbrl_dir == "cache/edinet/NEW_xbrl"
