import json
import sys
from datetime import datetime
from unittest.mock import AsyncMock, Mock, patch

from blue_ticker.api.edinet_cache_store import EdinetCacheStore
from blue_ticker.app.cli.main import main
from blue_ticker.utils.cache_paths import edinet_cache_dir


def _run_cli(monkeypatch, argv: list[str]) -> None:
    monkeypatch.setattr(sys, "argv", ["ticker", *argv])
    main()


def test_main_keyboard_interrupt_exits_cleanly(monkeypatch, capsys) -> None:
    monkeypatch.setattr(sys, "argv", ["ticker", "search", "トヨタ", "--format", "json"])

    with patch("blue_ticker.app.cli.search.master_data_manager.search", side_effect=KeyboardInterrupt):
        exit_code = main()

    captured = capsys.readouterr()
    assert exit_code == 130
    assert captured.out == ""
    assert captured.err == "\n中断しました。\n"


def test_main_cache_status_reports_missing_prepare_cache(monkeypatch, capsys, tmp_path) -> None:
    with patch("blue_ticker.app.cli.cache.settings_store") as settings:
        settings.cache_dir = str(tmp_path)

        _run_cli(monkeypatch, ["cache", "status", "--format", "json"])

    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["edinet_index_status"] == "missing"
    assert data["edinet_index_prepared_years"] == 0


def test_main_cache_status_reports_ready_prepare_cache(monkeypatch, capsys, tmp_path) -> None:
    store = EdinetCacheStore(edinet_cache_dir(tmp_path))
    current_year = datetime.now().year
    for offset in range(5):
        year = current_year - offset
        store.save_document_index(year, [{"docID": f"S100{year}"}], built_through=f"{year}-12-31")

    with patch("blue_ticker.app.cli.cache.settings_store") as settings:
        settings.cache_dir = str(tmp_path)

        _run_cli(monkeypatch, ["cache", "status", "--format", "json"])

    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["edinet_index_status"] == "ready"
    assert data["edinet_index_prepared_years"] == 5


def test_main_search_outputs_json(monkeypatch, capsys) -> None:
    results = [
        {"code": "7203", "name": "トヨタ自動車", "market": "プライム", "sector": "輸送用機器"},
    ]

    with patch("blue_ticker.app.cli.search.master_data_manager.search", return_value=results) as search:
        _run_cli(monkeypatch, ["search", "トヨタ", "--format", "json"])

    captured = capsys.readouterr()
    assert json.loads(captured.out) == results
    assert captured.err == ""
    search.assert_called_once_with("トヨタ")


def test_main_summarize_outputs_json_and_closes_service(monkeypatch, capsys) -> None:
    data_service = Mock()
    data_service.fetch_stock_basic_info.return_value = {
        "name": "トヨタ自動車",
        "market_name": "プライム",
    }
    data_service.get_raw_analysis_data = AsyncMock(return_value={
        "metrics": {
            "years": [
                {
                    "fy_end": "2024-03-31",
                    "RawData": {"CurPerType": "FY"},
                    "CalculatedData": {"Sales": 1_000.0},
                }
            ]
        }
    })
    data_service.close = AsyncMock()

    with (
        patch("blue_ticker.services.data_service.data_service", data_service),
        patch("blue_ticker.app.cli.summarize._ensure_edinet_index", new_callable=AsyncMock, return_value=True),
    ):
        _run_cli(monkeypatch, ["summarize", "7203", "--years", "2", "--format", "json", "--no-cache"])

    captured = capsys.readouterr()
    assert json.loads(captured.out)["metrics"]["years"][0]["CalculatedData"]["Sales"] == 1_000.0
    assert "分析中: 72030 トヨタ自動車" in captured.err
    data_service.get_raw_analysis_data.assert_awaited_once_with(
        "72030",
        use_cache=False,
        analysis_years=2,
        include_debug_fields=False,
    )
    data_service.close.assert_awaited_once()


def test_main_filings_outputs_json(monkeypatch, capsys) -> None:
    docs = [
        {"docID": "S100TEST", "docTypeCode": "120", "docDescription": "有価証券報告書"},
    ]
    data_service = Mock()
    data_service.search_filings = AsyncMock(return_value=docs)
    data_service.close = AsyncMock()

    with patch("blue_ticker.services.data_service.data_service", data_service):
        _run_cli(monkeypatch, ["filings", "7203", "--format", "json"])

    captured = capsys.readouterr()
    assert json.loads(captured.out) == docs
    data_service.search_filings.assert_awaited_once_with(
        "72030",
        max_years=3,
        doc_types=["120", "130", "140", "150", "160", "170"],
        max_documents=10,
    )
    data_service.close.assert_awaited_once()


def test_main_filings_accepts_years(monkeypatch, capsys) -> None:
    data_service = Mock()
    data_service.search_filings = AsyncMock(return_value=[])
    data_service.close = AsyncMock()

    with patch("blue_ticker.services.data_service.data_service", data_service):
        _run_cli(monkeypatch, ["filings", "7203", "--years", "6", "--format", "json"])

    captured = capsys.readouterr()
    assert "書類が見つかりませんでした" in captured.err
    data_service.search_filings.assert_awaited_once_with(
        "72030",
        max_years=6,
        doc_types=["120", "130", "140", "150", "160", "170"],
        max_documents=10,
    )
    data_service.close.assert_awaited_once()


def test_main_filing_outputs_json_with_sections(monkeypatch, capsys) -> None:
    result = {
        "doc_id": "S100TEST",
        "sections": {"mda": "経営成績の分析"},
    }
    data_service = Mock()
    data_service.extract_filing_content = AsyncMock(return_value=result)
    data_service.close = AsyncMock()

    with patch("blue_ticker.services.data_service.data_service", data_service):
        _run_cli(
            monkeypatch,
            ["filing", "7203", "--doc-id", "S100TEST", "--sections", "mda", "--format", "json"],
        )

    captured = capsys.readouterr()
    assert json.loads(captured.out) == result
    data_service.extract_filing_content.assert_awaited_once_with(
        "72030",
        doc_id="S100TEST",
        sections=["mda"],
    )
    data_service.close.assert_awaited_once()


def test_main_cache_clean_outputs_json(monkeypatch, capsys) -> None:
    summary = Mock()
    summary.to_dict.return_value = {
        "removed_files": 1,
        "removed_dirs": 2,
        "freed_bytes": 3,
        "scanned_files": 1,
        "scanned_dirs": 2,
        "dry_run": False,
    }
    pruner = Mock()
    pruner.prune.return_value = summary

    with (
        patch("blue_ticker.app.cli.cache.settings_store") as settings,
        patch("blue_ticker.app.cli.cache.CachePruner", return_value=pruner) as pruner_cls,
    ):
        settings.cache_dir = "/tmp/blue_ticker-cache"
        _run_cli(
            monkeypatch,
            [
                "cache",
                "clean",
                "--execute",
                "--edinet-search-days",
                "30",
                "--edinet-xbrl-days",
                "60",
                "--format",
                "json",
            ],
        )

    captured = capsys.readouterr()
    assert json.loads(captured.out)["freed_bytes"] == 3
    pruner_cls.assert_called_once_with("/tmp/blue_ticker-cache")
    pruner.prune.assert_called_once_with(
        dry_run=False,
        edinet_search_days=30,
        edinet_xbrl_days=60,
        edinet_doc_index_years=6,
    )


def test_main_cache_prepare_outputs_json(monkeypatch, capsys) -> None:
    with (
        patch("blue_ticker.app.cli.cache.settings_store") as settings,
        patch("blue_ticker.app.cli.cache.prepare_edinet_index_async", AsyncMock(return_value={
            "requested_years": 2,
            "prepared_years": 2,
            "entries": [
                {"year": 2026, "documents": 100, "status": "prepared"},
                {"year": 2025, "documents": 200, "status": "prepared"},
            ],
        })) as prepare,
    ):
        settings.cache_dir = "/tmp/blue_ticker-cache"
        settings.edinet_api_key = "dummy"
        _run_cli(monkeypatch, ["cache", "prepare", "--years", "2", "--format", "json"])

    captured = capsys.readouterr()
    assert json.loads(captured.out)["prepared_years"] == 2
    prepare.assert_awaited_once_with("dummy", "/tmp/blue_ticker-cache", 2)


def test_main_cache_refresh_outputs_json(monkeypatch, capsys) -> None:
    with (
        patch("blue_ticker.app.cli.cache.settings_store") as settings,
        patch("blue_ticker.app.cli.cache.refresh_edinet_index_async", AsyncMock(return_value={
            "requested_years": 2,
            "refreshed_years": 2,
            "entries": [
                {"year": 2026, "documents": 100, "status": "refreshed"},
                {"year": 2025, "documents": 200, "status": "refreshed"},
            ],
        })) as refresh,
    ):
        settings.cache_dir = "/tmp/blue_ticker-cache"
        settings.edinet_api_key = "dummy"
        _run_cli(monkeypatch, ["cache", "refresh", "--years", "2", "--format", "json"])

    captured = capsys.readouterr()
    assert json.loads(captured.out)["refreshed_years"] == 2
    refresh.assert_awaited_once_with("dummy", "/tmp/blue_ticker-cache", 2)


def test_main_cache_catchup_outputs_json(monkeypatch, capsys) -> None:
    with (
        patch("blue_ticker.app.cli.cache.settings_store") as settings,
        patch("blue_ticker.app.cli.cache.catchup_edinet_index_async", AsyncMock(return_value={
            "requested_years": 2,
            "caught_up_years": 2,
            "entries": [
                {"year": 2026, "documents": 100, "status": "caught_up"},
                {"year": 2025, "documents": 200, "status": "caught_up"},
            ],
        })) as catchup,
    ):
        settings.cache_dir = "/tmp/blue_ticker-cache"
        settings.edinet_api_key = "dummy"
        _run_cli(monkeypatch, ["cache", "catchup", "--years", "2", "--format", "json"])

    captured = capsys.readouterr()
    assert json.loads(captured.out)["caught_up_years"] == 2
    catchup.assert_awaited_once_with("dummy", "/tmp/blue_ticker-cache", 2)
