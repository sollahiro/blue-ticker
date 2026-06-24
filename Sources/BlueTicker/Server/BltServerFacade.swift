// blt-server の REST API が呼ぶ Core 側ファサード。
// HTTP トランスポート（BltServerCore ターゲット）から呼ばれ、計算済みの応答データを返す。
// このファイルは NIO に依存しない（トランスポートと分離）。
// 内部では CLI と同じ Services / Analysis 層を呼ぶ。

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - BltServerResponse

/// ファサードの応答。HTTP ステータスコードはトランスポート側が決める。
/// 戻り値パターン（error-handling.md）に従い、失敗は throw せず case で表現する。
public enum BltServerResponse {
    /// 成功。JSON 値（オブジェクト or 配列）。
    case ok(Any)
    /// 対象が見つからない（404 相当）。
    case notFound(String)
    /// 外部取得の失敗（502 相当）。
    case upstreamFailure(String)
}

// MARK: - BltServerContext

/// blt-server が共有するコンテキスト兼ファサード（EDINET クライアント・キャッシュを保持）。
/// 可変状態を持たないため `actor` ではなく `Sendable` struct。
public struct BltServerContext: Sendable {
    let edinetClient: EdinetAPIClient
    let cacheManager: CacheManager
    let cacheDir: URL

    init(apiKey: String, cacheDir: URL) {
        self.cacheDir = cacheDir
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        self.edinetClient = EdinetAPIClient(apiKey: apiKey, cacheStore: store)
        self.cacheManager = CacheManager(cacheDir: derivedCacheDir(cacheDir))
    }
}

// MARK: - Factory

/// EDINET API キーを解決する。env（BLT_EDINET_API_KEY）を優先し、未設定なら settingsStore に
/// フォールバックする。クラウド（keychain 非搭載の Linux サーバー）では env から注入する。
private func resolveEdinetApiKey() async -> String? {
    if let envKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"], !envKey.isEmpty {
        return envKey
    }
    let stored = await settingsStore.get(.edinetApiKey)
    return (stored?.isEmpty == false) ? stored : nil
}

/// EDINET API キー（env 優先）と設定から BltServerContext を構築する。
/// EDINET API キーが未設定なら nil を返す（呼び出し元がユーザー向けメッセージを出す）。
public func makeBltServerContext() async -> BltServerContext? {
    guard let key = await resolveEdinetApiKey() else {
        return nil
    }
    let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
    let cacheDir = URL(
        fileURLWithPath: cacheDirStr.isEmpty ? settingsStore.cacheDir.path : cacheDirStr)
    return BltServerContext(apiKey: key, cacheDir: cacheDir)
}

// MARK: - REST Facade

public extension BltServerContext {
    func searchCompanies(q: String) async -> BltServerResponse {
        let results = await masterDataManager.search(q, limit: 50)
        let json = results.map {
            ["code": $0.code, "name": $0.name, "sector": $0.sector, "market": $0.market]
        }
        return .ok(json)
    }

    func searchBySector(sector: String, limit: Int) async -> BltServerResponse {
        let results = await masterDataManager.searchBySector(sector, limit: limit)
        let json = results.map {
            ["code": $0.code, "name": $0.name, "sector": $0.sector, "market": $0.market]
        }
        return .ok(json)
    }

    func getFilings(code: String, maxYears: Int) async -> BltServerResponse {
        let stock = await masterDataManager.getByCode(code)
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

        return .ok(["code": code, "name": stock?.coName ?? "", "filings": filings])
    }

    func getFinancials(code: String, years: Int) async -> BltServerResponse {
        let analyzer = IndividualAnalyzer(edinetClient: edinetClient, cacheManager: cacheManager)
        guard let result = await analyzer.analyze(code: code, analysisYears: years) else {
            return .notFound("データが見つかりませんでした: \(code)")
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
        return .ok(json)
    }

    func getFilingContent(code: String, docId: String?, sections: [String]?) async -> BltServerResponse {
        let targetDocID: String
        if let d = docId, !d.isEmpty {
            targetDocID = d
        } else {
            let docs = await EdinetDiscovery.buildDocumentIndexForCode(
                code: code, client: edinetClient, analysisYears: 1
            )
            guard let latest = docs.first, let d = latest["docID"] as? String else {
                return .notFound("書類が見つかりませんでした: \(code)")
            }
            targetDocID = d
        }

        guard let xbrlDir = await edinetClient.downloadDocument(targetDocID) else {
            return .upstreamFailure("XBRLのダウンロードに失敗しました")
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

        return .ok(["code": code, "doc_id": targetDocID, "sections": extracted])
    }
}

// MARK: - Helpers

private extension BltServerContext {
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
