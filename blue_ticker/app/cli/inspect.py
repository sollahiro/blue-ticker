"""分析キャッシュの異常値候補スキャンコマンド。

決定的な整合性チェックで候補を列挙し、最終判断は人間（または
レビュー用LLM）に委ねる。JSON出力はそのままレビューの入力になる。
"""

import json
import sys

from blue_ticker.infrastructure.helpers import validate_stock_code
from blue_ticker.infrastructure.settings import settings_store
from blue_ticker.services.inspector import inspect_analysis_cache
from blue_ticker.utils.cache import CacheManager


def cmd_inspect(args):
    """異常値候補スキャンコマンド"""
    codes: list[str] = []
    for raw_code in getattr(args, "codes", None) or []:
        try:
            codes.append(validate_stock_code(raw_code))
        except ValueError as e:
            print(f"エラー: {e}", file=sys.stderr)
            return

    cache_manager = CacheManager(
        cache_dir=settings_store.cache_dir,
        enabled=True,
    )
    report = inspect_analysis_cache(cache_manager, codes=codes or None)

    if args.format == "json":
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return

    print(
        f"\n[異常値候補スキャン] 対象: {report['scanned_codes']} 銘柄 / {report['scanned_years']} 年度",
        file=sys.stderr,
    )
    candidates = report["candidates"]
    if not candidates:
        if report["scanned_codes"] == 0:
            print("分析キャッシュが見つかりませんでした。先に ticker summarize <code> を実行してください。", file=sys.stderr)
        else:
            print("異常値候補は見つかりませんでした。", file=sys.stderr)
        return

    print(f"候補: {len(candidates)} 件（最終判断は目視で行ってください）", file=sys.stderr)
    print("-" * 100, file=sys.stderr)
    print(f"{'重要度':<8} {'コード':<8} {'年度末':<12} {'チェック':<32} メッセージ", file=sys.stderr)
    print("-" * 100, file=sys.stderr)
    for candidate in candidates:
        print(
            f"{candidate['severity']:<8}"
            f" {candidate['code']:<8}"
            f" {candidate['fy_end'] or '-':<12}"
            f" {candidate['check']:<32}"
            f" {candidate['message']}",
            file=sys.stderr,
        )
    print("-" * 100, file=sys.stderr)
    print("根拠の値は --format json の evidence フィールドで確認できます。", file=sys.stderr)
