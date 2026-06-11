import json
import sys
from blue_ticker.services.master_data import master_data_manager


def cmd_search(args):
    """銘柄検索コマンド"""
    if not args.query:
        print("検索クエリを指定してください。", file=sys.stderr)
        return

    results = master_data_manager.search(args.query)
    if not results:
        print(f"'{args.query}' に一致する銘柄は見つかりませんでした。", file=sys.stderr)
        return

    if getattr(args, 'format', 'table') == 'json':
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return

    print(f"\n'{args.query}' の検索結果 ({len(results)}件):", file=sys.stderr)
    print("-" * 60, file=sys.stderr)
    print(f"{'コード':<8} {'銘柄名':<20} {'市場':<15} {'業種'}", file=sys.stderr)
    print("-" * 60, file=sys.stderr)
    for item in results:
        print(f"{item['code']:<8} {item['name']:<20} {item['market']:<15} {item['sector']}", file=sys.stderr)
    print("-" * 60, file=sys.stderr)
