import argparse
from blue_ticker import __version__
from blue_ticker.constants.api import ANALYZE_DEFAULT_YEARS, EDINET_FILINGS_DEFAULT_YEARS, EDINET_PREPARE_DEFAULT_YEARS


def build_parser() -> argparse.ArgumentParser:
    """CLIパーサーを構築します。"""
    parser = argparse.ArgumentParser(prog="ticker", description="BLUE TICKER: 日本株分析ツール CLI")
    parser.add_argument("--version", action="version", version=f"BLUE TICKER {__version__}")
    subparsers = parser.add_subparsers(dest="command", help="サブコマンド")

    # search
    search_parser = subparsers.add_parser("search", help="銘柄を検索")
    search_parser.add_argument("query", help="検索クエリ（銘柄名またはコード）")
    search_parser.add_argument("--format", choices=["table", "json"], default="json", help="出力形式")

    # summarize
    summarize_parser = subparsers.add_parser("summarize", help="銘柄の財務指標サマリーを表示")
    summarize_parser.add_argument("code", help="銘柄コード")
    summarize_parser.add_argument("--years", type=int, help=f"分析年数（デフォルト: {ANALYZE_DEFAULT_YEARS}）")
    summarize_parser.add_argument("--format", choices=["table", "json"], default="json", help="出力形式")
    summarize_parser.add_argument(
        "--no-cache",
        action="store_true",
        help="分析結果キャッシュを使用せず再計算する",
    )
    summarize_parser.add_argument(
        "--half", action="store_true",
        help="上半期(H1)・下半期(H2)の半期推移を表示する"
    )
    summarize_parser.add_argument(
        "--include-debug-fields", dest="include_debug_fields", action="store_true",
        help="MetricSources・IBDComponents 等のデバッグフィールドを JSON に含める"
    )

    # analyze
    analyze_parser = subparsers.add_parser("analyze", help="分析指標（ウォーターフォール分解等）を出力")
    analyze_parser.add_argument("code", help="銘柄コード")
    analyze_parser.add_argument("--years", type=int, help=f"分析年数（デフォルト: {ANALYZE_DEFAULT_YEARS}）")
    analyze_parser.add_argument(
        "--indicators",
        nargs="+",
        choices=["business-profit", "roic", "roe"],
        help="出力する分析指標（省略時は全指標）",
    )
    analyze_parser.add_argument("--format", choices=["table", "json"], default="json", help="出力形式")
    analyze_parser.add_argument(
        "--no-cache",
        action="store_true",
        help="分析結果キャッシュを使用せず再計算する",
    )

    # inspect
    inspect_parser = subparsers.add_parser("inspect", help="分析キャッシュを走査して異常値候補を検出")
    inspect_parser.add_argument("codes", nargs="*", help="銘柄コード（省略時はキャッシュ済み全銘柄）")
    inspect_parser.add_argument("--format", choices=["table", "json"], default="json", help="出力形式")

    # filings
    filings_parser = subparsers.add_parser("filings", help="EDINET書類一覧を取得")
    filings_parser.add_argument("code", help="銘柄コード")
    filings_parser.add_argument(
        "--years",
        type=int,
        default=EDINET_FILINGS_DEFAULT_YEARS,
        help=f"探索年数（デフォルト: {EDINET_FILINGS_DEFAULT_YEARS}）",
    )
    filings_parser.add_argument("--format", choices=["table", "json"], default="json", help="出力形式")

    # filing
    filing_parser = subparsers.add_parser("filing", help="EDINET書類の内容を抽出（JSON出力）")
    filing_parser.add_argument("code", help="銘柄コード")
    filing_parser.add_argument("--doc-id", dest="doc_id", help="書類ID (省略時は最新の有価証券報告書)")
    filing_parser.add_argument("--sections", nargs="+", help="抽出するセクション名 (複数指定可)")
    filing_parser.add_argument("--format", choices=["json"], default="json", help="出力形式")

    # config
    config_parser = subparsers.add_parser("config", help="設定の表示・変更")
    config_sub = config_parser.add_subparsers(dest="config_subcommand", help="設定サブコマンド")
    config_sub.add_parser("show", help="設定を表示")
    set_parser = config_sub.add_parser("set", help="値を設定")
    set_parser.add_argument("key", help="設定キー (edinet-key 等)")
    set_parser.add_argument("value", help="設定値")
    config_sub.add_parser("init", help="対話形式で初期設定")
    config_sub.add_parser("check", help="API設定の確認")

    # cache
    cache_parser = subparsers.add_parser("cache", help="キャッシュ管理")
    cache_sub = cache_parser.add_subparsers(dest="cache_subcommand", help="キャッシュサブコマンド")
    status_parser = cache_sub.add_parser("status", help="キャッシュ状態を表示")
    status_parser.add_argument(
        "--years",
        type=int,
        default=EDINET_PREPARE_DEFAULT_YEARS,
        help=f"確認する直近年数（デフォルト: {EDINET_PREPARE_DEFAULT_YEARS}）",
    )
    status_parser.add_argument("--format", choices=["table", "json"], default="table", help="出力形式")
    prepare_parser = cache_sub.add_parser("prepare", help="EDINET年次インデックスを事前準備")
    prepare_parser.add_argument(
        "--years",
        type=int,
        default=EDINET_PREPARE_DEFAULT_YEARS,
        help=f"準備する直近年数（デフォルト: {EDINET_PREPARE_DEFAULT_YEARS}）",
    )
    prepare_parser.add_argument("--format", choices=["table", "json"], default="table", help="出力形式")
    catchup_parser = cache_sub.add_parser("catchup", help="EDINET年次インデックスの不足分を取得")
    catchup_parser.add_argument(
        "--years",
        type=int,
        default=EDINET_PREPARE_DEFAULT_YEARS,
        help=f"差分更新する直近年数（デフォルト: {EDINET_PREPARE_DEFAULT_YEARS}）",
    )
    catchup_parser.add_argument("--format", choices=["table", "json"], default="table", help="出力形式")
    refresh_parser = cache_sub.add_parser("refresh", help="EDINET年次インデックスを更新")
    refresh_parser.add_argument(
        "--years",
        type=int,
        default=EDINET_PREPARE_DEFAULT_YEARS,
        help=f"更新する直近年数（デフォルト: {EDINET_PREPARE_DEFAULT_YEARS}）",
    )
    refresh_parser.add_argument("--format", choices=["table", "json"], default="table", help="出力形式")
    clean_parser = cache_sub.add_parser("clean", help="不要なキャッシュを削除")
    clean_parser.add_argument("--execute", action="store_true", help="実際に削除する（未指定時は dry-run）")
    clean_parser.add_argument(
        "--edinet-search-days",
        type=int,
        default=None,
        help="指定日数以上古い EDINET 検索キャッシュを削除",
    )
    clean_parser.add_argument(
        "--edinet-xbrl-days",
        type=int,
        default=None,
        help="指定日数以上古い EDINET XBRL 展開ディレクトリを削除",
    )
    clean_parser.add_argument(
        "--edinet-doc-index-years",
        type=int,
        default=6,
        help="保持する EDINET 年次インデックス年数（デフォルト: 6、0で全削除）",
    )
    clean_parser.add_argument("--format", choices=["table", "json"], default="table", help="出力形式")

    # sector
    sector_parser = subparsers.add_parser("sector", help="東証33業種で銘柄を検索")
    sector_parser.add_argument("sector", nargs="?", help="業種名（省略時は全業種一覧を表示）")
    sector_parser.add_argument("--format", choices=["table", "json"], default="json", help="出力形式")

    return parser
