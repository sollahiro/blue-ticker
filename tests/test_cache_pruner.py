import os
from datetime import datetime, timedelta

from blue_ticker.services.cache_pruner import CachePruner


def _touch_old(path, days: int) -> None:
    ts = (datetime.now() - timedelta(days=days)).timestamp()
    os.utime(path, (ts, ts))


def test_prune_edinet_by_age(tmp_path) -> None:
    edinet_dir = tmp_path / "edinet"
    edinet_dir.mkdir()

    old_search = edinet_dir / "search_2024-01-01.json"
    new_search = edinet_dir / "search_2024-02-01.json"
    old_search.write_text("[]", encoding="utf-8")
    new_search.write_text("[]", encoding="utf-8")
    _touch_old(old_search, 40)
    _touch_old(new_search, 5)

    old_xbrl = edinet_dir / "S100OLD_xbrl"
    new_xbrl = edinet_dir / "S100NEW_xbrl"
    old_xbrl.mkdir()
    new_xbrl.mkdir()
    (old_xbrl / "doc.xbrl").write_text("old", encoding="utf-8")
    (new_xbrl / "doc.xbrl").write_text("new", encoding="utf-8")
    _touch_old(old_xbrl, 40)
    _touch_old(new_xbrl, 5)

    summary = CachePruner(tmp_path).prune(
        dry_run=False,
        edinet_search_days=30,
        edinet_xbrl_days=30,
    )

    assert summary.removed_files == 1
    assert summary.removed_dirs == 1
    assert not old_search.exists()
    assert new_search.exists()
    assert not old_xbrl.exists()
    assert new_xbrl.exists()


def test_prune_edinet_doc_indexes_keeps_recent_years_by_default(tmp_path) -> None:
    current_year = datetime.now().year
    edinet_dir = tmp_path / "edinet"
    edinet_dir.mkdir()
    old_index = edinet_dir / f"doc_index_{current_year - 6}.json"
    kept_index = edinet_dir / f"doc_index_{current_year - 5}.json"
    old_index.write_text("{}", encoding="utf-8")
    kept_index.write_text("{}", encoding="utf-8")

    summary = CachePruner(tmp_path).prune(dry_run=False)

    assert summary.removed_files == 1
    assert not old_index.exists()
    assert kept_index.exists()


def test_prune_edinet_doc_indexes_can_keep_custom_years(tmp_path) -> None:
    current_year = datetime.now().year
    edinet_dir = tmp_path / "edinet"
    edinet_dir.mkdir()
    old_index = edinet_dir / f"doc_index_{current_year - 3}.json"
    kept_index = edinet_dir / f"doc_index_{current_year - 2}.json"
    old_index.write_text("{}", encoding="utf-8")
    kept_index.write_text("{}", encoding="utf-8")

    summary = CachePruner(tmp_path).prune(
        dry_run=False,
        edinet_doc_index_years=3,
    )

    assert summary.removed_files == 1
    assert not old_index.exists()
    assert kept_index.exists()


def test_stats_counts_cache_categories(tmp_path) -> None:
    from blue_ticker.utils.cache import CacheManager

    cache = CacheManager(cache_dir=str(tmp_path))
    cache.set("edinet_docs_72030_1", {"docs": []})
    cache.set("xbrl_parsed_S100TEST", {"data": {}})
    cache.set("individual_analysis_72030", {"metrics": {}})
    cache.set("half_year_periods_72030_3", [])
    (tmp_path / "manual_dump.json").write_text("{}", encoding="utf-8")

    edinet_dir = tmp_path / "edinet"
    edinet_dir.mkdir()
    (edinet_dir / "search_2024-01-01.json").write_text("[]", encoding="utf-8")
    (edinet_dir / "doc_index_2024.json").write_text("{}", encoding="utf-8")
    xbrl_dir = edinet_dir / "S100TEST_xbrl"
    xbrl_dir.mkdir()
    (xbrl_dir / "doc.xbrl").write_text("xbrl", encoding="utf-8")

    pruner = CachePruner(tmp_path)
    stats = pruner.stats()

    assert stats.total_files == 9
    assert stats.edinet_search_files == 1
    assert stats.edinet_search_bytes > 0
    assert stats.edinet_doc_index_files == 1
    assert stats.edinet_xbrl_dirs == 1
    assert stats.edinet_xbrl_bytes > 0
    assert stats.edinet_docs_cache_files == 1
    assert stats.xbrl_parse_cache_files == 1
    assert stats.individual_analysis_files == 1
    assert stats.half_year_analysis_files == 1
    assert stats.unknown_root_json_files == 1


def test_audit_lists_cache_categories(tmp_path) -> None:
    from blue_ticker.utils.cache import CacheManager

    cache = CacheManager(cache_dir=str(tmp_path))
    cache.set("edinet_docs_72030_1", {"docs": []})
    cache.set("xbrl_parsed_S100TEST", {"data": {}})
    cache.set("individual_analysis_72030", {"metrics": {}})
    cache.set("half_year_periods_72030_3", [])
    (tmp_path / "manual_dump.json").write_text("{}", encoding="utf-8")

    edinet_dir = tmp_path / "edinet"
    edinet_dir.mkdir()
    (edinet_dir / "search_2024-01-01.json").write_text("[]", encoding="utf-8")
    (edinet_dir / "doc_index_2024.json").write_text("{}", encoding="utf-8")
    (edinet_dir / "S100TEST_xbrl").mkdir()

    audit = CachePruner(tmp_path).audit()

    assert audit.unknown_root_json_files == ["manual_dump.json"]
    assert audit.edinet_search_files == ["search_2024-01-01.json"]
    assert audit.edinet_doc_index_files == ["doc_index_2024.json"]
    assert audit.edinet_xbrl_dirs == ["S100TEST_xbrl"]
    assert audit.edinet_docs_cache_files == ["edinet_docs_72030_1.json"]
    assert audit.xbrl_parse_cache_files == ["xbrl_parsed_S100TEST.json"]
    assert audit.individual_analysis_files == ["individual_analysis_72030.json"]
    assert audit.half_year_analysis_files == ["half_year_periods_72030_3.json"]
