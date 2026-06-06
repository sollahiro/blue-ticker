import json
import sys
import logging
from collections.abc import Mapping
import aiohttp
from blue_ticker.infrastructure.helpers import validate_stock_code
from blue_ticker.services.master_data import master_data_manager
from blue_ticker.utils.converters import extract_year_month
from blue_ticker.utils.metrics_access import metric_view
from blue_ticker.constants.api import ANALYZE_DEFAULT_YEARS, EDINET_FILINGS_DEFAULT_YEARS
from blue_ticker.constants.financial import MILLION_YEN

logger = logging.getLogger(__name__)


def _gross_profit_labels(calculated_data: Mapping[str, object]) -> tuple[str, str, str]:
    """売上総利益系の表示ラベルを返す。"""
    base_label_value = calculated_data.get("GrossProfitLabel", "売上総利益")
    base_label = base_label_value if isinstance(base_label_value, str) else "売上総利益"
    gross_profit_label = f"{base_label} (百万)"
    gross_profit_margin_label = (
        f"{base_label}率 (%)"
        if base_label != "売上総利益"
        else "粗利率 (%)"
    )
    gross_margin_change_label = (
        f"{base_label}率差影響"
        if base_label != "売上総利益"
        else "粗利率差影響"
    )
    return gross_profit_label, gross_profit_margin_label, gross_margin_change_label


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


async def cmd_analyze(args):
    """銘柄分析コマンド"""
    from blue_ticker.services.data_service import data_service

    try:
        code = validate_stock_code(args.code)
    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
        return

    include_debug = getattr(args, "include_debug_fields", False)
    requested_years = getattr(args, "years", None)
    if requested_years is not None and requested_years <= 0:
        print("エラー: years には正の整数を指定してください。", file=sys.stderr)
        return

    # --half が指定された場合は半期推移表示
    if getattr(args, "half", False):
        try:
            info = data_service.fetch_stock_basic_info(code)
            if not info.get("name"):
                print(f"エラー: 銘柄コード {code} が見つかりません。", file=sys.stderr)
                return

            half_years = requested_years or 3
            print(f"\n分析中: {code} {info['name']} ({info['market_name']}) ...", file=sys.stderr)
            print(f"分析対象期間: 直近 {half_years} 年分 (上半期 / 下半期)", file=sys.stderr)

            periods = await data_service.get_half_year_periods(
                code, years=half_years, use_cache=not args.no_cache, include_debug_fields=include_debug
            )
            if not periods:
                print("エラー: 財務データの取得に失敗しました。APIキーが正しく設定されているか確認してください。", file=sys.stderr)
                return

            if args.format == "json":
                print(json.dumps(periods, indent=2, ensure_ascii=False))
                return

            print(f"\n[半期財務推移]", file=sys.stderr)
            headers = ["項目 \\ 期"] + [p["label"] for p in periods]
            row_format = "{:<18}" + " {:>10}" * len(periods)
            sep = "-" * (18 + 11 * len(periods))
            print(sep, file=sys.stderr)
            print(row_format.format(*headers), file=sys.stderr)
            print(sep, file=sys.stderr)

            latest_period_data = periods[-1].get("data", {}) if periods else {}
            gross_profit_label, gross_profit_margin_label, gross_margin_change_label = (
                _gross_profit_labels(latest_period_data)
            )

            half_metrics_to_show = [
                ("売上高 (百万)",      lambda d: d.get("Sales")),
                (gross_profit_label,   lambda d: d.get("GrossProfit")),
                (gross_profit_margin_label, lambda d: d.get("GrossProfitMargin")),
                ("販管費 (百万)",      lambda d: d.get("SellingGeneralAdministrativeExpenses")),
                ("営業利益 (百万)",    lambda d: d.get("OP")),
                ("営業利益率 (%)",     lambda d: d.get("OperatingMargin")),
                ("事業利益 (百万)", lambda d: d.get("BusinessProfit")),
                ("事業利益率 (%)", lambda d: d.get("BusinessProfitMargin")),
                ("NOPAT (百万)",       lambda d: d.get("NOPAT")),
                ("純利益 (百万)",      lambda d: d.get("NP")),
                ("事業利益前年差", lambda d: d.get("OperatingProfitChange")),
                ("売上差影響",         lambda d: d.get("SalesChangeImpact")),
                (gross_margin_change_label, lambda d: d.get("GrossMarginChangeImpact")),
                ("販管費差影響",        lambda d: d.get("SGAChangeImpact")),
                ("ROIC (%)",           lambda d: d.get("ROIC")),
                ("NOPATマージン (%)",   lambda d: d.get("NOPATMargin")),
                ("投下資本回転率 (倍)", lambda d: d.get("InvestedCapitalTurnover")),
                ("ROIC前年差 (%)",     lambda d: d.get("ROICDelta")),
                ("  NOPATマージン差影響",  lambda d: d.get("ROICMarginEffect")),
                ("  投下資本回転率差影響", lambda d: d.get("ROICTurnoverEffect")),
                ("営業CF (百万)",      lambda d: d.get("CFO")),
                ("投資CF (百万)",      lambda d: d.get("CFI")),
                ("フリーCF (百万)",    lambda d: d.get("CFC", d.get("FreeCF"))),
                ("DocID",              lambda d: d.get("DocID")),
            ]

            for label, func in half_metrics_to_show:
                row = [label]
                for p in periods:
                    val = func(p["data"])
                    if val is None:
                        row.append(f"{'-':>10}")
                    elif isinstance(val, str):
                        row.append(f"{val:>10}")
                    else:
                        row.append(f"{val:>10.2f}")
                print(row_format.format(*row), file=sys.stderr)

            print(sep, file=sys.stderr)
        except ValueError as e:
            print(f"エラー: {e}", file=sys.stderr)
        except aiohttp.ClientError as e:
            print(f"エラー: {e}", file=sys.stderr)
            logger.exception(e)
        finally:
            await data_service.close()
        return

    try:
        # 銘柄情報の確認
        info = data_service.fetch_stock_basic_info(code)
        if not info.get("name"):
            print(f"エラー: 銘柄コード {code} が見つかりません。", file=sys.stderr)
            return

        # 分析年数の決定
        years_to_analyze = requested_years or ANALYZE_DEFAULT_YEARS

        print(f"\n分析中: {code} {info['name']} ({info['market_name']}) ...", file=sys.stderr)
        years_label = f"直近 {years_to_analyze} 年分" if years_to_analyze else "全期間"
        print(f"分析対象期間: {years_label}", file=sys.stderr)
        # data_service を使って生の財務データを取得
        result = await data_service.get_raw_analysis_data(
            code, use_cache=not args.no_cache, analysis_years=years_to_analyze, include_debug_fields=include_debug,
        )

        if not result or not result.get("metrics"):
            print("エラー: 財務データの取得に失敗しました。APIキーが正しく設定されているか確認してください。", file=sys.stderr)
            return

        if args.format == "json":
            print(json.dumps(result, indent=2, ensure_ascii=False))
            return

        # 指標データの取得
        metrics = result.get("metrics", {})
        years_data = metrics.get("years", [])
        if not years_data:
            print("エラー: 指標データが見つかりませんでした。", file=sys.stderr)
            return

        # 横並びのテーブル表示
        print(f"\n[主要財務指標の推移]", file=sys.stderr)

        # ヘッダー作成（年度）
        headers = ["項目 \\ 年度"]
        periods = []
        for y_data in reversed(years_data): # 古い順に表示
            fy_end = y_data.get("fy_end", "不明")
            year, month = extract_year_month(fy_end)
            if year is not None:
                period_str = f"{str(year)[2:]}/{month:02d}"
            else:
                period_str = fy_end
            per_type = y_data.get("RawData", {}).get("CurPerType", "FY")
            if per_type == "2Q":
                period_str += "(2Q)"
            headers.append(period_str)
            periods.append(y_data)

        row_format = "{:<16}" + " {:>10}" * len(periods)
        print("-" * (16 + 11 * len(periods)), file=sys.stderr)
        print(row_format.format(*headers), file=sys.stderr)
        print("-" * (16 + 11 * len(periods)), file=sys.stderr)

        # 各指標の行を作成
        def get_op_margin(c):
            return c.get("OperatingMargin") or (c.get("OP") / c.get("Sales") * 100 if c.get("OP") and c.get("Sales") else None)

        def to_million(value):
            return value / MILLION_YEN if value is not None else None

        def raw_value(period, key):
            return (period.get("RawData") or {}).get(key)

        def calculated_metric(getter):
            return lambda period: getter(metric_view(period))

        def raw_metric(key):
            return lambda period: raw_value(period, key)

        # IFRS金融会社は純収益・事業利益ラベルを使う（最新年度のラベルで判定）
        latest_display_data = metric_view(periods[-1]) if periods else {}
        sales_label = latest_display_data.get("SalesLabel", "売上高") + " (百万)"
        gross_profit_label, gross_profit_margin_label, gross_margin_change_label = (
            _gross_profit_labels(latest_display_data)
        )
        op_label = latest_display_data.get("OPLabel", "営業利益") + " (百万)"
        op_margin_label = latest_display_data.get("OPLabel", "営業利益") + "率 (%)"

        metrics_to_show = [
            (sales_label,             calculated_metric(lambda c: c.get("Sales"))),
            ("受注高 (百万)",          calculated_metric(lambda c: c.get("OrderIntake"))),
            ("受注残高 (百万)",        calculated_metric(lambda c: c.get("OrderBacklog"))),
            (gross_profit_label,       calculated_metric(lambda c: c.get("GrossProfit"))),
            (gross_profit_margin_label, calculated_metric(lambda c: c.get("GrossProfitMargin"))),
            ("販管費 (百万)",          calculated_metric(lambda c: c.get("SellingGeneralAdministrativeExpenses"))),
            ("事業利益 (百万)",         calculated_metric(lambda c: c.get("BusinessProfit"))),
            ("事業利益率 (%)",          calculated_metric(lambda c: c.get("BusinessProfitMargin"))),
            (op_label,                calculated_metric(lambda c: c.get("OP"))),
            (op_margin_label,         calculated_metric(get_op_margin)),
            ("NOPAT (百万)",           calculated_metric(lambda c: c.get("NOPAT"))),
            ("純利益 (百万)",          calculated_metric(lambda c: c.get("NP"))),
            ("実効税率 (%)",            calculated_metric(lambda c: c.get("EffectiveTaxRate"))),
            ("事業利益前年差",          calculated_metric(lambda c: c.get("OperatingProfitChange"))),
            ("  売上差影響",           calculated_metric(lambda c: c.get("SalesChangeImpact"))),
            (f"  {gross_margin_change_label}", calculated_metric(lambda c: c.get("GrossMarginChangeImpact"))),
            ("  販管費差影響",          calculated_metric(lambda c: c.get("SGAChangeImpact"))),
            ("ROE (%)",               calculated_metric(lambda c: c.get("ROE"))),
            ("ROIC (%)",              calculated_metric(lambda c: c.get("ROIC"))),
            ("NOPATマージン (%)",      calculated_metric(lambda c: c.get("NOPATMargin"))),
            ("投下資本回転率 (倍)",    calculated_metric(lambda c: c.get("InvestedCapitalTurnover"))),
            ("ROIC前年差 (%)",        calculated_metric(lambda c: c.get("ROICDelta"))),
            ("  NOPATマージン差影響",  calculated_metric(lambda c: c.get("ROICMarginEffect"))),
            ("  投下資本回転率差影響", calculated_metric(lambda c: c.get("ROICTurnoverEffect"))),
            ("投下資本 (百万)",         calculated_metric(lambda c: (c.get("InterestBearingDebt") + c.get("NetAssets")) if c.get("InterestBearingDebt") is not None and c.get("NetAssets") is not None else None)),
            ("有利子負債合計 (百万)",   calculated_metric(lambda c: c.get("InterestBearingDebt"))),
            ("支払利息 (百万)",         calculated_metric(lambda c: c.get("InterestExpense"))),
            ("総資産 (百万)",           calculated_metric(lambda c: c.get("TotalAssets"))),
            ("流動資産 (百万)",         calculated_metric(lambda c: c.get("CurrentAssets"))),
            ("固定資産 (百万)",         calculated_metric(lambda c: c.get("NonCurrentAssets"))),
            ("  有形固定資産合計 (百万)", calculated_metric(lambda c: c.get("PPETotal"))),
            ("  建物及び構築物 (百万)", calculated_metric(lambda c: c.get("PPEBuildings"))),
            ("  土地 (百万)",          calculated_metric(lambda c: c.get("PPELand"))),
            ("  機械装置及び運搬具 (百万)", calculated_metric(lambda c: c.get("PPEMachinery"))),
            ("  工具器具及び備品 (百万)", calculated_metric(lambda c: c.get("PPETools"))),
            ("  建設仮勘定 (百万)",    calculated_metric(lambda c: c.get("PPEConstructionInProgress"))),
            ("  その他PPE (百万)",     calculated_metric(lambda c: c.get("PPEOthers"))),
            ("流動負債 (百万)",         calculated_metric(lambda c: c.get("CurrentLiabilities"))),
            ("固定負債 (百万)",         calculated_metric(lambda c: c.get("NonCurrentLiabilities"))),
            ("純資産 (百万)",           calculated_metric(lambda c: c.get("NetAssets"))),
            ("現金及び現金同等物 (百万)", calculated_metric(lambda c: c.get("CashEq"))),
            ("ネットキャッシュ (百万)",   calculated_metric(lambda c: c.get("NetCash"))),
            ("営業CF (百万)",          calculated_metric(lambda c: c.get("CFO"))),
            ("減価償却費 (百万)",      calculated_metric(lambda c: c.get("DepreciationAmortization"))),
            ("その他現金化差分 (百万)", calculated_metric(lambda c: c.get("OtherCashConversionGap"))),
            ("投資CF (百万)",          calculated_metric(lambda c: c.get("CFI"))),
            ("フリーCF (百万)",        calculated_metric(lambda c: c.get("CFC"))),
            ("設備投資 (百万)",        calculated_metric(lambda c: c.get("Capex"))),
            ("研究開発費 (百万)",      calculated_metric(lambda c: c.get("RD"))),
            ("自己株式取得 (百万)",    calculated_metric(lambda c: c.get("Buyback"))),
            ("EPS (円)",              raw_metric("EPS")),
            ("BPS (円)",              raw_metric("BPS")),
            ("中間配当 (円)",         raw_metric("Div2Q")),
            ("年間配当 (円)",         raw_metric("DivAnn")),
            ("年間配当総額 (百万)",   lambda p: to_million(raw_value(p, "DivTotalAnn"))),
            ("配当性向 (%)",           calculated_metric(lambda c: c.get("PayoutRatio"))),
            ("期末発行済株式数 (株)", raw_metric("ShOutFY"), "int"),
            ("従業員数 (人)",           calculated_metric(lambda c: c.get("Employees")), "int"),
            ("DocID",                  calculated_metric(lambda c: c.get("DocID"))),
        ]

        for metric_def in metrics_to_show:
            label, func = metric_def[0], metric_def[1]
            fmt_hint = metric_def[2] if len(metric_def) > 2 else None
            values = [func(p) for p in periods]
            if all(v is None for v in values):
                continue
            row = [label]
            for val in values:
                if val is None:
                    row.append(f"{'-':>10}")
                elif isinstance(val, str):
                    row.append(f"{val:>10}")
                elif fmt_hint == "int":
                    row.append(f"{int(val):>10,}")
                else:
                    row.append(f"{val:>10.2f}")
            print(row_format.format(*row), file=sys.stderr)

        print("-" * (16 + 11 * len(periods)), file=sys.stderr)

        print("\n定性情報は ticker filing コマンドで抽出できます。", file=sys.stderr)

    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
    except aiohttp.ClientError as e:
        print(f"エラー: {e}", file=sys.stderr)
        logger.exception(e)
    finally:
        await data_service.close()


async def cmd_filings(args):
    """EDINET書類一覧コマンド"""
    from blue_ticker.services.data_service import data_service

    try:
        code = validate_stock_code(args.code)
        years = getattr(args, "years", EDINET_FILINGS_DEFAULT_YEARS)
        if years <= 0:
            print("エラー: years には正の整数を指定してください。", file=sys.stderr)
            return
        docs = await data_service.search_filings(
            code,
            max_years=years,
            doc_types=["120", "130", "140", "150", "160", "170"],
            max_documents=10,
        )
        if not docs:
            print(f"書類が見つかりませんでした: {code}", file=sys.stderr)
            return
        if args.format == "json":
            print(json.dumps(docs, indent=2, ensure_ascii=False))
        else:
            print(f"\n[EDINET書類一覧] {code} ({len(docs)}件)", file=sys.stderr)
            print("-" * 80, file=sys.stderr)
            print(f"{'書類ID':<16} {'種別':<6} {'提出日時':<20} {'書類名'}", file=sys.stderr)
            print("-" * 80, file=sys.stderr)
            for doc in docs:
                print(
                    f"{doc.get('docID',''):<16}"
                    f" {doc.get('docTypeCode',''):<6}"
                    f" {doc.get('submitDateTime',''):<20}"
                    f" {doc.get('docDescription','')}",
                    file=sys.stderr,
                )
            print("-" * 80, file=sys.stderr)
    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
    except aiohttp.ClientError as e:
        print(f"エラー: {e}", file=sys.stderr)
        logger.exception(e)
    finally:
        await data_service.close()


async def cmd_filing(args):
    """EDINET書類抽出コマンド"""
    from blue_ticker.services.data_service import data_service

    try:
        code = validate_stock_code(args.code)
        doc_id = getattr(args, "doc_id", None)
        sections = getattr(args, "sections", None) or []
        result = await data_service.extract_filing_content(
            code,
            doc_id=doc_id or None,
            sections=sections or None,
        )
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except ValueError as e:
        print(f"エラー: {e}", file=sys.stderr)
    except aiohttp.ClientError as e:
        print(f"エラー: {e}", file=sys.stderr)
        logger.exception(e)
    finally:
        await data_service.close()
