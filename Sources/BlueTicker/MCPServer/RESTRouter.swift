import Foundation
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - RESTRouter

/// iOS app など非 MCP クライアント向けの REST API ルーター。
/// 内部では MCP ツールと同じ Services 層を呼ぶ。
struct RESTRouter: Sendable {
    let context: BltServerContext

    func handle(method: String, path: String, queryParams: [String: String], body: Data?) async -> RESTResult {
        guard method.uppercased() == "GET" else {
            return .error(statusCode: 405, message: "Method not allowed")
        }
        return await handleGET(path: path, queryParams: queryParams)
    }

    private func handleGET(path: String, queryParams: [String: String]) async -> RESTResult {
        if path == "/v1/companies" {
            return await searchCompanies(q: queryParams["q"] ?? "")
        }
        if let code = segment(of: path, between: "/v1/companies/", and: "/filings") {
            return await getFilings(code: code, maxYears: Int(queryParams["max_years"] ?? "5") ?? 5)
        }
        if let code = segment(of: path, between: "/v1/companies/", and: "/financials") {
            return await getFinancials(code: code, years: Int(queryParams["years"] ?? "5") ?? 5)
        }
        if let code = segment(of: path, between: "/v1/companies/", and: "/filing-content") {
            let sections = queryParams["sections"].map { $0.split(separator: ",").map(String.init) }
            return await getFilingContent(code: code, docId: queryParams["doc_id"], sections: sections)
        }
        if let sector = segment(of: path, between: "/v1/sectors/", and: "/companies") {
            return await searchBySector(sector: sector, limit: Int(queryParams["limit"] ?? "20") ?? 20)
        }
        return .error(statusCode: 404, message: "Not found: \(path)")
    }
}

// MARK: - Route Handlers

private extension RESTRouter {
    func searchCompanies(q: String) async -> RESTResult {
        let results = await masterDataManager.search(q, limit: 50)
        let json = results.map { ["code": $0.code, "name": $0.name, "sector": $0.sector, "market": $0.market] }
        return .json(json)
    }

    func searchBySector(sector: String, limit: Int) async -> RESTResult {
        let results = await masterDataManager.searchBySector(sector, limit: limit)
        let json = results.map { ["code": $0.code, "name": $0.name, "sector": $0.sector, "market": $0.market] }
        return .json(json)
    }

    func getFilings(code: String, maxYears: Int) async -> RESTResult {
        let stock = await masterDataManager.getByCode(code)
        let edinetClient = context.edinetClient
        let service = FilingService(edinetClient: edinetClient)
        let docs = await service.searchFilings(code: code, maxYears: maxYears, maxDocuments: 50)

        let filings: [[String: Any]] = docs.map { doc in
            let docType = doc["docTypeCode"] as? String ?? ""
            let rawFyEnd = doc["edinet_fy_end"] as? String ?? ""
            let fyEnd = rawFyEnd.count >= 7 ? String(rawFyEnd.prefix(7)) : rawFyEnd
            let submitAt = (doc["submitDateTime"] as? String) ?? (doc["submitDate"] as? String) ?? ""
            return [
                "doc_id": doc["docID"] as? String ?? "",
                "doc_type": docType,
                "doc_type_label": docTypeLabel(docType) ?? (doc["docDescription"] as? String ?? ""),
                "fy_end": fyEnd,
                "submitted_at": submitAt,
            ]
        }

        return .json(["code": code, "name": stock?.coName ?? "", "filings": filings])
    }

    func getFinancials(code: String, years: Int) async -> RESTResult {
        let edinetClient = context.edinetClient
        let cacheManager = context.cacheManager
        let analyzer = IndividualAnalyzer(edinetClient: edinetClient, cacheManager: cacheManager)
        guard let result = await analyzer.analyze(code: code, analysisYears: years) else {
            return .error(statusCode: 404, message: "データが見つかりませんでした: \(code)")
        }
        let stock = await masterDataManager.getByCode(code)
        let json: [String: Any] = [
            "code": code,
            "name": stock?.coName ?? result.code ?? "",
            "sector": stock?.s33nm ?? "",
            "market": stock?.mktNm ?? "",
            "currency": "JPY",
            "unit": "百万円",
            "years": (result.years ?? []).map { flattenYearEntry($0) },
        ]
        return .json(json)
    }

    func getFilingContent(code: String, docId: String?, sections: [String]?) async -> RESTResult {
        let edinetClient = context.edinetClient

        let targetDocID: String
        if let d = docId, !d.isEmpty {
            targetDocID = d
        } else {
            let docs = await EdinetDiscovery.buildDocumentIndexForCode(
                code: code, client: edinetClient, analysisYears: 1
            )
            guard let latest = docs.first, let d = latest["docID"] as? String else {
                return .error(statusCode: 404, message: "書類が見つかりませんでした: \(code)")
            }
            targetDocID = d
        }

        guard let xbrlDir = await edinetClient.downloadDocument(targetDocID) else {
            return .error(statusCode: 502, message: "XBRLのダウンロードに失敗しました")
        }

        let targetSections = sections ?? Array(xbrlSections.keys) + SegmentExtractor.specialSectionKeys
        let parser = XBRLParser()
        var extracted: [String: Any] = [:]
        for key in targetSections {
            if let seg = SegmentExtractor.extractSpecialSection(key, xbrlDir: xbrlDir) {
                extracted[key] = seg.toDictionary()
            } else if let def = xbrlSections[key] {
                extracted[key] = parser.extractSection(in: xbrlDir, sectionName: def.title) ?? ""
            }
        }

        return .json(["code": code, "doc_id": targetDocID, "sections": extracted])
    }
}

// MARK: - Helpers

private extension RESTRouter {
    /// `/v1/companies/7203/filings` → segment(between:"/v1/companies/", and:"/filings") → "7203"
    func segment(of path: String, between prefix: String, and suffix: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let raw = String(path[start..<end])
        return raw.removingPercentEncoding ?? raw
    }

    func docTypeLabel(_ code: String) -> String? {
        switch code {
        case "120": return "有価証券報告書"
        case "130": return "訂正有価証券報告書"
        case "140": return "半期報告書"
        case "150": return "訂正半期報告書"
        case "160": return "四半期報告書"
        case "170": return "訂正四半期報告書"
        default: return nil
        }
    }

    func flattenYearEntry(_ entry: YearEntry) -> [String: Any] {
        let raw = entry.rawData
        let calc = entry.calculatedData
        return [
            "fy_end": entry.fyEnd as Any,
            "financial_period": entry.financialPeriod,
            "doc_id": calc.docID as Any,
            "sales": raw.sales as Any,
            "gross_profit": calc.grossProfit as Any,
            "gross_profit_margin": calc.grossProfitMargin as Any,
            "operating_profit": raw.op as Any,
            "operating_margin": calc.operatingMargin as Any,
            "net_profit": raw.np as Any,
            "cfo": raw.cfo as Any,
            "cfi": raw.cfi as Any,
            "cfc": calc.cfc as Any,
            "eps": raw.eps as Any,
            "bps": raw.bps as Any,
            "dividends_per_share": raw.divTotalAnn as Any,
            "payout_ratio": raw.payoutRatioAnn as Any,
            "total_assets": calc.totalAssets as Any,
            "net_assets": calc.netAssets as Any,
            "interest_bearing_debt": calc.interestBearingDebt as Any,
            "roe": calc.roe as Any,
            "roic": calc.roic as Any,
            "employees": calc.employees as Any,
            // 事業利益増減分析
            "business_profit": calc.businessProfit as Any,
            "business_profit_margin": calc.businessProfitMargin as Any,
            "business_profit_change": calc.businessProfitChange as Any,
            "sales_change_impact": calc.salesChangeImpact as Any,
            "gross_margin_change_impact": calc.grossMarginChangeImpact as Any,
            "sga_change_impact": calc.sgaChangeImpact as Any,
            // ROIC増減分析
            "nopat_margin": calc.nopatMargin as Any,
            "invested_capital_turnover": calc.investedCapitalTurnover as Any,
            "roic_delta": calc.roicDelta as Any,
            "roic_margin_effect": calc.roicMarginEffect as Any,
            "roic_turnover_effect": calc.roicTurnoverEffect as Any,
            // ROE増減分析
            "net_margin": calc.netMargin as Any,
            "asset_turnover": calc.assetTurnover as Any,
            "financial_leverage": calc.financialLeverage as Any,
            "roe_delta": calc.roeDelta as Any,
            "roe_net_margin_effect": calc.roeNetMarginEffect as Any,
            "roe_asset_turnover_effect": calc.roeAssetTurnoverEffect as Any,
            "roe_leverage_effect": calc.roeLeverageEffect as Any,
            // ネットキャッシュ
            "cash_equivalents": raw.cashEq as Any,
            "net_cash": calc.netCash as Any,
            // 運転資本・CCC
            "accounts_receivable": calc.accountsReceivable as Any,
            "inventory": calc.inventory as Any,
            "accounts_payable": calc.accountsPayable as Any,
            "working_capital": calc.workingCapital as Any,
            "dso": calc.dso as Any,
            "dio": calc.dio as Any,
            "dpo": calc.dpo as Any,
            "ccc": calc.ccc as Any,
        ]
    }
}
