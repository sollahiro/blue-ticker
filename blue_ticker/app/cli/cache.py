import json
import sys
import asyncio
from datetime import datetime
from typing import Any

from blue_ticker.api.edinet_cache_store import EdinetCacheStore
from blue_ticker.api.edinet_client import EdinetAPIClient
from blue_ticker.constants.api import EDINET_PREPARE_DEFAULT_YEARS
from blue_ticker.infrastructure.settings import settings_store
from blue_ticker.utils.cache_paths import edinet_cache_dir
from blue_ticker.services.cache_pruner import CachePruner


async def prepare_edinet_index_async(api_key: str, cache_dir: str, years: int) -> dict[str, Any]:
    """直近 years 年分の EDINET 年次インデックスを準備する。"""
    client = EdinetAPIClient(
        api_key=api_key,
        cache_dir=str(edinet_cache_dir(cache_dir)),
    )
    current_year = datetime.now().year
    target_years = [current_year - offset for offset in range(years)]
    entries: list[dict[str, Any]] = []
    try:
        for year in target_years:
            docs = await client.ensure_document_index_for_year(year)
            entries.append({"year": year, "documents": len(docs), "status": "prepared"})
    finally:
        await client.close()

    return {
        "requested_years": years,
        "prepared_years": len(entries),
        "entries": entries,
    }


async def refresh_edinet_index_async(api_key: str, cache_dir: str, years: int) -> dict[str, Any]:
    """直近 years 年分の EDINET 年次インデックスを今日まで更新する。"""
    client = EdinetAPIClient(
        api_key=api_key,
        cache_dir=str(edinet_cache_dir(cache_dir)),
    )
    current_year = datetime.now().year
    target_years = [current_year - offset for offset in range(years)]
    entries: list[dict[str, Any]] = []
    try:
        for year in target_years:
            docs = await client.refresh_document_index_for_year(year)
            entries.append({"year": year, "documents": len(docs), "status": "refreshed"})
    finally:
        await client.close()

    return {
        "requested_years": years,
        "refreshed_years": len(entries),
        "entries": entries,
    }


async def catchup_edinet_index_async(api_key: str, cache_dir: str, years: int) -> dict[str, Any]:
    """直近 years 年分の EDINET 年次インデックスを差分更新する。"""
    client = EdinetAPIClient(
        api_key=api_key,
        cache_dir=str(edinet_cache_dir(cache_dir)),
    )
    current_year = datetime.now().year
    target_years = [current_year - offset for offset in range(years)]
    entries: list[dict[str, Any]] = []
    try:
        for year in target_years:
            docs = await client.catchup_document_index_for_year(year)
            entries.append({"year": year, "documents": len(docs), "status": "caught_up"})
    finally:
        await client.close()

    return {
        "requested_years": years,
        "caught_up_years": len(entries),
        "entries": entries,
    }


def cache_status(cache_dir: str, years: int = EDINET_PREPARE_DEFAULT_YEARS) -> dict[str, Any]:
    """ユーザー向けキャッシュ状態を返す。"""
    store = EdinetCacheStore(edinet_cache_dir(cache_dir))
    pruner = CachePruner(cache_dir)
    stats = pruner.stats().to_dict()
    current_year = datetime.now().year
    target_years = [current_year - offset for offset in range(years)]
    index_entries: list[dict[str, Any]] = []
    prepared = 0
    stale = False
    today = datetime.now().strftime("%Y-%m-%d")
    for year in target_years:
        info = store.load_document_index_info(year, allow_stale=True)
        if info is None:
            index_entries.append({"year": year, "status": "missing", "documents": 0, "built_through": None})
            continue
        prepared += 1
        built_through = info.get("built_through")
        year_end = f"{year}-12-31"
        required_through = min(year_end, today)
        entry_status = "ready" if isinstance(built_through, str) and built_through >= required_through else "stale"
        stale = stale or entry_status == "stale"
        documents = info.get("documents")
        index_entries.append({
            "year": year,
            "status": entry_status,
            "documents": len(documents) if isinstance(documents, list) else 0,
            "built_through": built_through if isinstance(built_through, str) else None,
        })

    if prepared < len(target_years):
        index_status = "missing"
        next_action = f"ticker cache prepare --years {years}"
    elif stale:
        index_status = "stale"
        next_action = f"ticker cache catchup --years {years}"
    else:
        index_status = "ready"
        next_action = None

    return {
        "cache_dir": cache_dir,
        "edinet_index_status": index_status,
        "edinet_index_prepared_years": prepared,
        "edinet_index_requested_years": len(target_years),
        "edinet_index_entries": index_entries,
        "edinet_xbrl_dirs": stats["edinet_xbrl_dirs"],
        "edinet_xbrl_bytes": stats["edinet_xbrl_bytes"],
        "analysis_files": int(stats["individual_analysis_files"]) + int(stats["half_year_analysis_files"]),
        "analysis_bytes": int(stats["individual_analysis_bytes"]) + int(stats["half_year_analysis_bytes"]),
        "total_bytes": stats["total_bytes"],
        "next_action": next_action,
    }


def print_prepare_loading(years: int) -> None:
    """EDINETキャッシュ準備中の状態を表示する。"""
    print(f"Now Loading... EDINET年次インデックスを準備しています（直近{years}年分）", file=sys.stderr)


def print_prepare_done(data: dict[str, Any]) -> None:
    """EDINETキャッシュ準備完了を表示する。"""
    print(f"Ready. EDINETキャッシュを準備しました: {data['prepared_years']}年分", file=sys.stderr)


def print_catchup_loading(years: int) -> None:
    """EDINETキャッシュ差分更新中の状態を表示する。"""
    print(f"Now Loading... EDINET年次インデックスの不足分を取得しています（直近{years}年分）", file=sys.stderr)


def print_catchup_done(data: dict[str, Any]) -> None:
    """EDINETキャッシュ差分更新完了を表示する。"""
    print(f"Ready. EDINETキャッシュを差分更新しました: {data['caught_up_years']}年分", file=sys.stderr)


def cmd_cache(args, parser) -> None:
    """キャッシュ管理コマンド"""
    if args.cache_subcommand == "status":
        years = getattr(args, "years", EDINET_PREPARE_DEFAULT_YEARS)
        if years <= 0:
            print("エラー: years には正の整数を指定してください。", file=sys.stderr)
            return
        data = cache_status(settings_store.cache_dir, years=years)
        if args.format == "json":
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return

        print("cache status", file=sys.stderr)
        print(f"  dir:           {data['cache_dir']}", file=sys.stderr)
        print(
            f"  EDINET index:  {data['edinet_index_status']} "
            f"({data['edinet_index_prepared_years']}/{data['edinet_index_requested_years']} years)",
            file=sys.stderr,
        )
        for entry in data["edinet_index_entries"]:
            if not isinstance(entry, dict):
                continue
            print(
                f"    {entry.get('year')}: {entry.get('status')} "
                f"documents={entry.get('documents')} built_through={entry.get('built_through') or '-'}",
                file=sys.stderr,
            )
        print(f"  XBRL cache:    {data['edinet_xbrl_dirs']} dirs ({_mb(data['edinet_xbrl_bytes'])})", file=sys.stderr)
        print(f"  analysis:      {data['analysis_files']} files ({_mb(data['analysis_bytes'])})", file=sys.stderr)
        if data["next_action"]:
            print(f"  next action:   {data['next_action']}", file=sys.stderr)
        return

    if args.cache_subcommand == "prepare":
        years = getattr(args, "years", EDINET_PREPARE_DEFAULT_YEARS)
        if years <= 0:
            print("エラー: years には正の整数を指定してください。", file=sys.stderr)
            return
        if not settings_store.edinet_api_key:
            print("EDINET APIキーが未設定です。ticker config set edinet-key <KEY> を実行してください。", file=sys.stderr)
            return

        if args.format != "json":
            print_prepare_loading(years)
        data = asyncio.run(
            prepare_edinet_index_async(
                settings_store.edinet_api_key,
                settings_store.cache_dir,
                years,
            )
        )
        if args.format == "json":
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return

        print_prepare_done(data)
        print("cache prepare", file=sys.stderr)
        print(f"  requested years: {data['requested_years']}", file=sys.stderr)
        print(f"  prepared years:  {data['prepared_years']}", file=sys.stderr)
        entries = data["entries"]
        if isinstance(entries, list):
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                print(
                    f"  prepared {entry.get('year')} "
                    f"documents={entry.get('documents')}",
                    file=sys.stderr,
                )
        return

    if args.cache_subcommand == "refresh":
        years = getattr(args, "years", EDINET_PREPARE_DEFAULT_YEARS)
        if years <= 0:
            print("エラー: years には正の整数を指定してください。", file=sys.stderr)
            return
        if not settings_store.edinet_api_key:
            print("EDINET APIキーが未設定です。ticker config set edinet-key <KEY> を実行してください。", file=sys.stderr)
            return
        if args.format != "json":
            print(f"Now Loading... EDINET年次インデックスを更新しています（直近{years}年分）", file=sys.stderr)
        data = asyncio.run(
            refresh_edinet_index_async(
                settings_store.edinet_api_key,
                settings_store.cache_dir,
                years,
            )
        )
        if args.format == "json":
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return
        print(f"Ready. EDINETキャッシュを更新しました: {data['refreshed_years']}年分", file=sys.stderr)
        return

    if args.cache_subcommand == "catchup":
        years = getattr(args, "years", EDINET_PREPARE_DEFAULT_YEARS)
        if years <= 0:
            print("エラー: years には正の整数を指定してください。", file=sys.stderr)
            return
        if not settings_store.edinet_api_key:
            print("EDINET APIキーが未設定です。ticker config set edinet-key <KEY> を実行してください。", file=sys.stderr)
            return
        if args.format != "json":
            print_catchup_loading(years)
        data = asyncio.run(
            catchup_edinet_index_async(
                settings_store.edinet_api_key,
                settings_store.cache_dir,
                years,
            )
        )
        if args.format == "json":
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return
        print_catchup_done(data)
        return

    if args.cache_subcommand == "clean":
        pruner = CachePruner(settings_store.cache_dir)
        summary = pruner.prune(
            dry_run=not args.execute,
            edinet_search_days=args.edinet_search_days,
            edinet_xbrl_days=args.edinet_xbrl_days,
            edinet_doc_index_years=args.edinet_doc_index_years,
        )
        data = summary.to_dict()
        if args.format == "json":
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return

        mode = "dry-run" if data["dry_run"] else "executed"
        mb = data["freed_bytes"] / 1024 / 1024
        print(f"cache clean ({mode})", file=sys.stderr)
        print(f"  removed files: {data['removed_files']}", file=sys.stderr)
        print(f"  removed dirs:  {data['removed_dirs']}", file=sys.stderr)
        print(f"  freed:         {mb:.2f} MB", file=sys.stderr)
        return

    parser.print_help()


def _mb(value: object) -> str:
    if isinstance(value, int):
        size = value
    elif isinstance(value, str) and value.isdigit():
        size = int(value)
    else:
        size = 0
    return f"{size / 1024 / 1024:.2f} MB"
