from typing import Any

from mcp.server.fastmcp import FastMCP

from blue_ticker.services.data_service import data_service


def _flatten_year(year: dict[str, Any]) -> dict[str, Any]:
    raw: dict[str, Any] = year.get("RawData") or {}
    calc: dict[str, Any] = year.get("CalculatedData") or {}
    return {
        "fy_end": year.get("fy_end"),
        "financial_period": year.get("FinancialPeriod"),
        "doc_id": calc.get("DocID"),
        # 損益（百万円）
        "sales": raw.get("Sales"),
        "gross_profit": calc.get("GrossProfit"),
        "gross_profit_margin": calc.get("GrossProfitMargin"),
        "operating_profit": raw.get("OP"),
        "operating_margin": calc.get("OperatingMargin"),
        "net_profit": raw.get("NP"),
        # キャッシュフロー（百万円）
        "cfo": raw.get("CFO"),
        "cfi": raw.get("CFI"),
        "cfc": calc.get("CFC"),
        # 株主指標（円）
        "eps": raw.get("EPS"),
        "bps": raw.get("BPS"),
        "dividends_per_share": raw.get("DivTotalAnn"),
        "payout_ratio": raw.get("PayoutRatioAnn"),
        # バランスシート（百万円）
        "total_assets": calc.get("TotalAssets"),
        "net_assets": calc.get("NetAssets"),
        "interest_bearing_debt": calc.get("InterestBearingDebt"),
        # 収益性・資本効率（%）
        "roe": calc.get("ROE"),
        "roic": calc.get("ROIC"),
        # 規模
        "employees": calc.get("Employees"),
    }


def register_financial_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def get_financial_summary(code: str, years: int = 5) -> dict[str, Any]:
        """銘柄コードの財務サマリーを年度別に返します。
        損益・CF・バランスシート・収益性指標を含みます。
        金額単位は百万円（JPY）、比率は%、株主指標は円。
        初回はEDINETからXBRL取得・解析を行うため数秒かかります。2回目以降はキャッシュから即返します。
        """
        result = await data_service.get_raw_analysis_data(code, analysis_years=years)
        if not result:
            return {"code": code, "error": "データが見つかりませんでした"}

        metrics: dict[str, Any] = result.get("metrics") or {}
        year_entries: list[dict[str, Any]] = metrics.get("years") or []

        return {
            "code": code,
            "name": result.get("CoName"),
            "sector": result.get("S33Nm"),
            "market": result.get("MktNm"),
            "currency": "JPY",
            "unit": "百万円",
            "years": [_flatten_year(y) for y in year_entries],
        }
