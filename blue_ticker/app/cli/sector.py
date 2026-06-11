import json
import sys
from blue_ticker.services.master_data import master_data_manager


def cmd_sector(args):
    """業種検索コマンド"""
    sector_query = getattr(args, "sector", None)
    fmt = getattr(args, "format", "table")

    if not sector_query:
        sectors = master_data_manager.list_sectors()
        if fmt == "json":
            print(json.dumps(sectors, indent=2, ensure_ascii=False))
            return
        print(f"\nEDINET業種一覧 ({len(sectors)}業種):", file=sys.stderr)
        print("-" * 50, file=sys.stderr)
        print(f"{'コード':<8} {'業種名':<20} {'銘柄数':>6}", file=sys.stderr)
        print("-" * 50, file=sys.stderr)
        for s in sectors:
            print(f"{s['code']:<8} {s['name']:<20} {s['count']:>6}件", file=sys.stderr)
        print("-" * 50, file=sys.stderr)
        return

    results = master_data_manager.search_by_sector(sector_query)
    if not results:
        print(f"'{sector_query}' に一致する業種の銘柄は見つかりませんでした。", file=sys.stderr)
        return

    if fmt == "json":
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return

    sector_label = results[0]["sector"] if results else sector_query
    print(f"\n[{sector_label}] の銘柄一覧 ({len(results)}件):", file=sys.stderr)
    print("-" * 55, file=sys.stderr)
    print(f"{'コード':<8} {'銘柄名':<25} {'市場'}", file=sys.stderr)
    print("-" * 55, file=sys.stderr)
    for item in results:
        print(f"{item['code']:<8} {item['name']:<25} {item['market']}", file=sys.stderr)
    print("-" * 55, file=sys.stderr)
