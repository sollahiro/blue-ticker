// MCP サーバーのツール定義とハンドラ登録。
// Python blue_ticker/mcp_server/ の移植。

import Foundation
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - BltServerContext

/// MCP サーバー全体で共有するコンテキスト（EDINET クライアント・キャッシュ）。
actor BltServerContext {
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

// MARK: - Server Factory

func makeBltServer(context: BltServerContext, transport: StatefulHTTPServerTransport) async -> Server {
    let server = Server(
        name: "blt-server",
        version: "26.6.0",
        capabilities: Server.Capabilities(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: allTools())
    }

    await server.withMethodHandler(CallTool.self) { params in
        await handleCallTool(params: params, context: context)
    }

    return server
}

// MARK: - Tool Definitions

private func allTools() -> [Tool] {
    [
        Tool(
            name: "search_companies",
            description: "銘柄コードまたは名称で企業を検索します。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("検索クエリ（銘柄コードまたは企業名）"),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "search_by_sector",
            description: "東証33業種で銘柄を検索します。業種名の部分一致で絞り込めます。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sector": .object([
                        "type": .string("string"),
                        "description": .string("業種名（部分一致）"),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("返却件数上限"),
                        "default": .int(20),
                    ]),
                ]),
                "required": .array([.string("sector")]),
            ])
        ),
        Tool(
            name: "get_filings",
            description: "銘柄コードに紐づく EDINET 書類一覧を取得します。書類一覧は事前キャッシュから返します。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "max_years": .object([
                        "type": .string("integer"),
                        "description": .string("取得年数"),
                        "default": .int(5),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "get_financial_summary",
            description: """
                銘柄コードの財務サマリーを年度別に返します。
                損益・CF・バランスシート・収益性指標を含みます。
                金額単位は百万円（JPY）、比率は%、株主指標は円。
                初回は EDINET から XBRL 取得・解析を行うため数秒かかります。2回目以降はキャッシュから即返します。
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "years": .object([
                        "type": .string("integer"),
                        "description": .string("取得年数"),
                        "default": .int(5),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "get_filing_content",
            description: """
                EDINET 書類からセクションテキストを抽出します。
                doc_id を省略すると最新の有価証券報告書を使用します。
                sections を省略すると全セクションを返します。
                利用可能なセクション: business_risks, mda, capex_overview, major_facilities, facility_plans, research_and_development, segments, geography
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("銘柄コード（例: 6103）"),
                    ]),
                    "doc_id": .object([
                        "type": .string("string"),
                        "description": .string("書類ID（省略時は最新の有価証券報告書）"),
                    ]),
                    "sections": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("抽出セクションのリスト（省略時は全セクション）"),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ),
        Tool(
            name: "sync_document_list",
            description: "EDINET 書類一覧を最新状態に同期します（管理用）。直近 years 年分の差分を取得します。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "years": .object([
                        "type": .string("integer"),
                        "description": .string("同期年数"),
                        "default": .int(2),
                    ]),
                ]),
            ])
        ),
    ]
}

// MARK: - Tool Dispatch

private func handleCallTool(params: CallTool.Parameters, context: BltServerContext) async -> CallTool.Result {
    do {
        let json = try await dispatchTool(params: params, context: context)
        let text = toJSONString(json) ?? "{}"
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    } catch {
        let msg = "{\"error\": \"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        return .init(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: true)
    }
}

private func dispatchTool(params: CallTool.Parameters, context: BltServerContext) async throws -> Any {
    let args = params.arguments ?? [:]

    switch params.name {
    case "search_companies":
        let query = args["query"]?.stringValue ?? ""
        let results = await masterDataManager.search(query, limit: 50)
        return results.map { ["code": $0.code, "name": $0.name, "sector": $0.sector, "market": $0.market] }

    case "search_by_sector":
        let sector = args["sector"]?.stringValue ?? ""
        let limit = args["limit"]?.intValue ?? 20
        let results = await masterDataManager.searchBySector(sector, limit: limit)
        return results.map { ["code": $0.code, "name": $0.name, "sector": $0.sector, "market": $0.market] }

    case "get_filings":
        return try await toolGetFilings(args: args, context: context)

    case "get_financial_summary":
        return try await toolGetFinancialSummary(args: args, context: context)

    case "get_filing_content":
        return try await toolGetFilingContent(args: args, context: context)

    case "sync_document_list":
        return try await toolSyncDocumentList(args: args, context: context)

    default:
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
}

// MARK: - Individual Tool Implementations

private let docTypeLabels: [String: String] = [
    "120": "有価証券報告書",
    "130": "訂正有価証券報告書",
    "140": "半期報告書",
    "150": "訂正半期報告書",
    "160": "四半期報告書",
    "170": "訂正四半期報告書",
]

private func toolGetFilings(args: [String: Value], context: BltServerContext) async throws -> Any {
    let code = args["code"]?.stringValue ?? ""
    let maxYears = args["max_years"]?.intValue ?? 5

    let stock = await masterDataManager.getByCode(code)
    let edinetClient = await context.edinetClient
    let service = FilingService(edinetClient: edinetClient)
    let docs = await service.searchFilings(code: code, maxYears: maxYears, maxDocuments: 50)

    let filings: [[String: Any]] = docs.map { doc -> [String: Any] in
        let docType = doc["docTypeCode"] as? String ?? ""
        let rawFyEnd = doc["edinet_fy_end"] as? String ?? ""
        let fyEnd = rawFyEnd.count >= 7 ? String(rawFyEnd.prefix(7)) : rawFyEnd
        let submitAt = (doc["submitDateTime"] as? String) ?? (doc["submitDate"] as? String) ?? ""
        return [
            "doc_id": doc["docID"] as? String ?? "",
            "doc_type": docType,
            "doc_type_label": docTypeLabels[docType] ?? (doc["docDescription"] as? String ?? ""),
            "fy_end": fyEnd,
            "submitted_at": submitAt,
        ]
    }

    return [
        "code": code,
        "name": stock?.coName ?? "",
        "filings": filings,
    ]
}

private func toolGetFinancialSummary(args: [String: Value], context: BltServerContext) async throws -> Any {
    let code = args["code"]?.stringValue ?? ""
    let years = args["years"]?.intValue ?? 5

    let edinetClient = await context.edinetClient
    let cacheManager = await context.cacheManager
    let analyzer = IndividualAnalyzer(edinetClient: edinetClient, cacheManager: cacheManager)
    guard let result = await analyzer.analyze(code: code, analysisYears: years) else {
        return ["code": code, "error": "データが見つかりませんでした"]
    }

    let stock = await masterDataManager.getByCode(code)
    let yearEntries: [[String: Any]] = (result.years ?? []).map { flattenYearEntry($0) }

    return [
        "code": code,
        "name": stock?.coName ?? result.code ?? "",
        "sector": stock?.s33nm ?? "",
        "market": stock?.mktNm ?? "",
        "currency": "JPY",
        "unit": "百万円",
        "years": yearEntries,
    ]
}

private func flattenYearEntry(_ entry: YearEntry) -> [String: Any] {
    let raw = entry.rawData
    let calc = entry.calculatedData
    var d: [String: Any] = [:]
    d["fy_end"] = entry.fyEnd as Any
    d["financial_period"] = entry.financialPeriod
    d["doc_id"] = calc.docID as Any
    d["sales"] = raw.sales as Any
    d["gross_profit"] = calc.grossProfit as Any
    d["gross_profit_margin"] = calc.grossProfitMargin as Any
    d["operating_profit"] = raw.op as Any
    d["operating_margin"] = calc.operatingMargin as Any
    d["net_profit"] = raw.np as Any
    d["cfo"] = raw.cfo as Any
    d["cfi"] = raw.cfi as Any
    d["cfc"] = calc.cfc as Any
    d["eps"] = raw.eps as Any
    d["bps"] = raw.bps as Any
    d["dividends_per_share"] = raw.divTotalAnn as Any
    d["payout_ratio"] = raw.payoutRatioAnn as Any
    d["total_assets"] = calc.totalAssets as Any
    d["net_assets"] = calc.netAssets as Any
    d["interest_bearing_debt"] = calc.interestBearingDebt as Any
    d["roe"] = calc.roe as Any
    d["roic"] = calc.roic as Any
    d["employees"] = calc.employees as Any
    return d
}

private func toolGetFilingContent(args: [String: Value], context: BltServerContext) async throws -> Any {
    let code = args["code"]?.stringValue ?? ""
    let docIdArg = args["doc_id"]?.stringValue
    let sectionsArg: [String]? = args["sections"]?.arrayValue?.compactMap { $0.stringValue }

    let edinetClient = await context.edinetClient

    let targetDocID: String
    if let d = docIdArg, !d.isEmpty {
        targetDocID = d
    } else {
        let docs = await EdinetDiscovery.buildDocumentIndexForCode(
            code: code, client: edinetClient, analysisYears: 1
        )
        guard let latest = docs.first, let d = latest["docID"] as? String else {
            return ["code": code, "error": "書類が見つかりませんでした"]
        }
        targetDocID = d
    }

    guard let xbrlDir = await edinetClient.downloadDocument(targetDocID) else {
        return ["code": code, "doc_id": targetDocID, "error": "XBRLのダウンロードに失敗しました"]
    }

    let targetSections = sectionsArg ?? Array(xbrlSections.keys) + SegmentExtractor.specialSectionKeys
    let parser = XBRLParser()
    var extracted: [String: Any] = [:]
    for key in targetSections {
        if let seg = SegmentExtractor.extractSpecialSection(key, xbrlDir: xbrlDir) {
            extracted[key] = seg.toDictionary()
        } else if let def = xbrlSections[key] {
            extracted[key] = parser.extractSection(in: xbrlDir, sectionName: def.title) ?? ""
        }
    }

    return ["code": code, "doc_id": targetDocID, "sections": extracted]
}

private func toolSyncDocumentList(args: [String: Value], context: BltServerContext) async throws -> Any {
    let years = args["years"]?.intValue ?? 2
    let edinetClient = await context.edinetClient

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let currentYear = calendar.component(.year, from: Date())

    var entries: [[String: Any]] = []
    for offset in 0..<years {
        let year = currentYear - offset
        let docs = await edinetClient.catchupDocumentIndexForYear(year)
        entries.append(["year": year, "documents": docs.count, "status": "synced"])
    }

    let total = entries.reduce(0) { $0 + ($1["documents"] as? Int ?? 0) }
    return [
        "status": "ok",
        "last_run_at": ISO8601DateFormatter().string(from: Date()),
        "synced_years": entries.count,
        "total_docs": total,
        "entries": entries,
    ]
}

// MARK: - JSON Helpers

private func toJSONString(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value) else {
        if let s = value as? String { return "\"\(s)\"" }
        return "\(value)"
    }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8)
    else { return nil }
    return str
}
