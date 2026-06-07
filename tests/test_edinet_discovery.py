from datetime import date
from unittest.mock import AsyncMock, Mock

import pytest

from blue_ticker.utils import edinet_discovery


@pytest.mark.asyncio
async def test_find_half_report_accepts_160_with_fy_period_end(monkeypatch) -> None:
    async def fake_fetch(_client, _start: date, _end: date):
        return {
            "2024-11-12": [{
                "docID": "S100UOCS",
                "secCode": "28020",
                "docTypeCode": "160",
                "docDescription": "半期報告書－第147期(2024/04/01－2025/03/31)",
                "periodStart": "2024-04-01",
                "periodEnd": "2025-03-31",
                "submitDateTime": "2024-11-12 13:08",
            }]
        }

    monkeypatch.setattr(edinet_discovery, "_fetch_date_range_cached", fake_fetch)

    doc = await edinet_discovery._find_half_report_for_fy(
        "28020",
        date(2024, 4, 1),
        date(2025, 3, 31),
        Mock(),
    )

    assert doc is not None
    assert doc["docID"] == "S100UOCS"
    assert doc["edinet_fy_end"] == "2025-03-31"
    assert doc["edinet_period_start"] == "2024-04-01"
    assert doc["edinet_period_end"] == "2024-09-30"
    assert doc["period_type"] == "2Q"


@pytest.mark.asyncio
async def test_find_half_report_accepts_legacy_140_with_q2_period_end(monkeypatch) -> None:
    async def fake_fetch(_client, _start: date, _end: date):
        return {
            "2023-11-09": [{
                "docID": "S100S3PK",
                "secCode": "28020",
                "docTypeCode": "140",
                "docDescription": "四半期報告書－第146期第2四半期(2023/07/01－2023/09/30)",
                "periodStart": "2023-07-01",
                "periodEnd": "2023-09-30",
                "submitDateTime": "2023-11-09 14:57",
            }]
        }

    monkeypatch.setattr(edinet_discovery, "_fetch_date_range_cached", fake_fetch)

    doc = await edinet_discovery._find_half_report_for_fy(
        "28020",
        date(2023, 4, 1),
        date(2024, 3, 31),
        Mock(),
    )

    assert doc is not None
    assert doc["docID"] == "S100S3PK"
    assert doc["edinet_fy_end"] == "2024-03-31"
    assert doc["edinet_period_start"] == "2023-04-01"
    assert doc["edinet_period_end"] == "2023-09-30"
    assert doc["period_type"] == "2Q"


# ---------------------------------------------------------------------------
# build_document_index_for_code
# ---------------------------------------------------------------------------

def _make_annual_doc(doc_id: str, edinet_code: str, period_start: str, period_end: str, submit: str) -> dict:
    return {
        "docID": doc_id,
        "edinetCode": edinet_code,
        "secCode": "98430",
        "docTypeCode": "120",
        "periodStart": period_start,
        "periodEnd": period_end,
        "submitDateTime": submit,
    }


def _make_amendment_doc(doc_id: str, edinet_code: str, parent_id: str, submit: str) -> dict:
    return {
        "docID": doc_id,
        "edinetCode": edinet_code,
        "docTypeCode": "130",
        "parentDocID": parent_id,
        "submitDateTime": submit,
    }


@pytest.mark.asyncio
async def test_build_document_index_finds_docs_across_fiscal_year_change(monkeypatch) -> None:
    """決算期変更（3月末→12月末）があっても edinetCode ベースで全履歴を取得できること。"""
    edinet_code = "E12345"

    # 最新有報: 12月末決算に変更後の最初の年度（9ヶ月）
    recent_doc = _make_annual_doc("S100NEW1", edinet_code, "2024-04-01", "2024-12-31", "2025-03-28 10:00")

    # 年次インデックスに入っているドキュメント（旧3月末パターン2件 + 新12月末1件 + 訂正1件 + 別会社1件）
    year_index: dict[int, list[dict]] = {
        2021: [_make_annual_doc("S100OLD1", edinet_code, "2020-04-01", "2021-03-31", "2021-06-25 10:00")],
        2022: [_make_annual_doc("S100OLD2", edinet_code, "2021-04-01", "2022-03-31", "2022-06-24 10:00")],
        2025: [
            recent_doc,
            _make_amendment_doc("S100AMEND", edinet_code, "S100NEW1", "2025-04-10 10:00"),
            # 別会社: フィルタされるべき
            _make_annual_doc("S100OTHER", "E99999", "2024-01-01", "2024-12-31", "2025-03-28 10:00"),
        ],
    }

    monkeypatch.setattr(
        edinet_discovery, "_find_most_recent_annual_report", AsyncMock(return_value=recent_doc)
    )

    mock_client = Mock()
    mock_client.ensure_document_index_for_year = AsyncMock(
        side_effect=lambda y: year_index.get(y, [])
    )

    docs, not_found = await edinet_discovery.build_document_index_for_code(
        "9843", mock_client, analysis_years=3
    )

    annual = [d for d in docs if d.get("docTypeCode") == "120"]
    amendments = [d for d in docs if d.get("_is_amendment")]

    # 旧3月末2件 + 新12月末1件 = 計3件取得できる
    assert len(annual) == 3
    fy_ends = {d["edinet_fy_end"] for d in annual}
    assert "2024-12-31" in fy_ends
    assert "2022-03-31" in fy_ends
    assert "2021-03-31" in fy_ends

    # 別会社はフィルタされる
    assert all(d.get("edinetCode") == edinet_code for d in annual)

    # 訂正書類が正しくリンクされる
    assert len(amendments) == 1
    assert amendments[0]["docID"] == "S100AMEND"
    assert amendments[0]["edinet_fy_end"] == "2024-12-31"

    # not_found_fy_ends は常に空（旧インタフェース互換）
    assert not_found == []


@pytest.mark.asyncio
async def test_build_document_index_returns_empty_when_no_recent_doc(monkeypatch) -> None:
    monkeypatch.setattr(
        edinet_discovery, "_find_most_recent_annual_report", AsyncMock(return_value=None)
    )
    docs, not_found = await edinet_discovery.build_document_index_for_code("9999", Mock())
    assert docs == []
    assert not_found == []


@pytest.mark.asyncio
async def test_build_document_index_returns_empty_when_edinet_code_missing(monkeypatch) -> None:
    recent_doc = {"docID": "S100X", "secCode": "99990", "docTypeCode": "120", "periodEnd": "2025-03-31"}
    monkeypatch.setattr(
        edinet_discovery, "_find_most_recent_annual_report", AsyncMock(return_value=recent_doc)
    )
    docs, not_found = await edinet_discovery.build_document_index_for_code("9999", Mock())
    assert docs == []
    assert not_found == []


@pytest.mark.asyncio
async def test_build_document_index_returns_empty_when_period_end_unparseable(monkeypatch) -> None:
    recent_doc = {"docID": "S100X", "edinetCode": "E12345", "docTypeCode": "120", "periodEnd": "invalid"}
    monkeypatch.setattr(
        edinet_discovery, "_find_most_recent_annual_report", AsyncMock(return_value=recent_doc)
    )
    docs, not_found = await edinet_discovery.build_document_index_for_code("9999", Mock())
    assert docs == []
    assert not_found == []


@pytest.mark.asyncio
async def test_build_document_index_uses_year_minus_1_when_period_start_missing(monkeypatch) -> None:
    """periodStart がない書類は fiscal_year = pe_dt.year - 1 にフォールバックする。"""
    edinet_code = "E12345"
    doc_no_start = {
        "docID": "S100NS",
        "edinetCode": edinet_code,
        "secCode": "98430",
        "docTypeCode": "120",
        "periodEnd": "2025-12-31",  # periodStart なし
        "submitDateTime": "2026-03-28 10:00",
    }
    monkeypatch.setattr(
        edinet_discovery, "_find_most_recent_annual_report", AsyncMock(return_value=doc_no_start)
    )
    mock_client = Mock()
    mock_client.ensure_document_index_for_year = AsyncMock(
        side_effect=lambda y: [doc_no_start] if y == 2026 else []
    )
    docs, _ = await edinet_discovery.build_document_index_for_code("9843", mock_client, analysis_years=1)
    annual = [d for d in docs if d.get("docTypeCode") == "120"]
    assert len(annual) == 1
    assert annual[0]["fiscal_year"] == 2024  # 2025 - 1


@pytest.mark.asyncio
async def test_build_document_index_slices_to_analysis_years(monkeypatch) -> None:
    """年次インデックスに analysis_years を超える有報があっても上位 N 件に絞られる。"""
    edinet_code = "E12345"
    # 提出年ごとに1件ずつ配置（年次インデックスは提出日ベース → 重複なし）
    # periodEnd 2019-2025, 提出日 2020-2026（今年 = 2026 内に収まるよう設計）
    all_annual = [
        _make_annual_doc(f"S100{i:03d}", edinet_code, f"{2019+i}-01-01", f"{2019+i}-12-31", f"{2020+i}-03-01 10:00")
        for i in range(7)
    ]
    by_submit_year: dict[int, list[dict]] = {}
    for doc in all_annual:
        submit_year = int(doc["submitDateTime"][:4])
        by_submit_year.setdefault(submit_year, []).append(doc)

    recent = all_annual[-1]  # periodEnd = 2025-12-31, submit = 2026-03-01
    monkeypatch.setattr(
        edinet_discovery, "_find_most_recent_annual_report", AsyncMock(return_value=recent)
    )
    mock_client = Mock()
    mock_client.ensure_document_index_for_year = AsyncMock(
        side_effect=lambda y: by_submit_year.get(y, [])
    )
    docs, _ = await edinet_discovery.build_document_index_for_code("9843", mock_client, analysis_years=3)
    annual = [d for d in docs if d.get("docTypeCode") == "120"]
    assert len(annual) == 3
    # 最新3件（periodEnd 降順）
    assert annual[0]["edinet_fy_end"] == "2025-12-31"
    assert annual[1]["edinet_fy_end"] == "2024-12-31"
    assert annual[2]["edinet_fy_end"] == "2023-12-31"
