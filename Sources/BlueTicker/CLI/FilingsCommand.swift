import ArgumentParser
import Foundation

struct FilingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filings",
        abstract: "銘柄の有価証券報告書一覧を表示します"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .shortAndLong, help: "取得年数")
    var years: Int = Api.filingsDefaultYears

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        if let remote = try await RemoteBackend.clientIfEnabled() {
            try await runRemote(remote)
            return
        }

        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            printError("エラー: EDINET API キーが設定されていません。ticker config set --edinet-api-key <KEY> で設定してください。\n")
            throw ExitCode.failure
        }
        let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
        let cacheDir = URL(fileURLWithPath: cacheDirStr)
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)
        let service = FilingService(edinetClient: client)

        let docs = await service.searchFilings(
            code: code,
            maxYears: years,
            docTypes: ["120", "130", "140", "150", "160", "170"],
            maxDocuments: 10
        )

        if docs.isEmpty {
            printError("書類が見つかりませんでした: \(code)\n")
            throw ExitCode.failure
        }

        if json {
            let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            if let data = try? JSONSerialization.data(withJSONObject: docs, options: opts),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printTable(
                columns: [
                    TableColumn("書類ID", width: 16),
                    TableColumn("種別", width: 6),
                    TableColumn("提出日時", width: 20),
                    TableColumn("書類名", width: 60),
                ],
                rows: docs.map { [
                    $0["docID"] as? String ?? "",
                    $0["docTypeCode"] as? String ?? "",
                    $0["submitDateTime"] as? String ?? "",
                    $0["docDescription"] as? String ?? "",
                ]}
            )
        }
    }

    /// remote バックエンド経路。計算済み書類一覧を受け取り、ローカルと同じ表で表示する。
    private func runRemote(_ remote: RemoteAPIClient) async throws {
        let filings: [RemoteFilings.Entry]
        switch await remote.getFilings(code: code, maxYears: years) {
        case .ok(let r): filings = r.filings
        case .notFound(let m), .failure(let m): printError(m + "\n"); throw ExitCode.failure
        }

        if filings.isEmpty {
            printError("書類が見つかりませんでした: \(code)\n")
            throw ExitCode.failure
        }

        if json {
            printJSON(filings)
        } else {
            printTable(
                columns: [
                    TableColumn("書類ID", width: 16),
                    TableColumn("種別", width: 6),
                    TableColumn("提出日時", width: 20),
                    TableColumn("書類名", width: 60),
                ],
                rows: filings.map { [$0.docId, $0.docType, $0.submittedAt, $0.docTypeLabel] }
            )
        }
    }
}

struct FilingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filing",
        abstract: "有価証券報告書のセクション内容を抽出します"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .long, help: "書類ID（省略時は最新の有価証券報告書）")
    var docId: String?

    @Option(name: .long, parsing: .upToNextOption, help: "抽出セクション: business_risks/mda/capex_overview/major_facilities/facility_plans/research_and_development/segments/geography/management_policy")
    var sections: [String] = []

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let validSections = Set(xbrlSections.keys).union(SegmentExtractor.specialSectionKeys)
        let unknown = sections.filter { !validSections.contains($0) }
        guard unknown.isEmpty else {
            printError("エラー: 不明なセクション: \(unknown.joined(separator: ", "))。有効: \(validSections.sorted().joined(separator: ", "))\n")
            throw ExitCode.failure
        }

        if let remote = try await RemoteBackend.clientIfEnabled() {
            try await runRemote(remote)
            return
        }

        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            printError("エラー: EDINET API キーが設定されていません。ticker config set --edinet-api-key <KEY> で設定してください。\n")
            throw ExitCode.failure
        }

        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)
        let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
        let cacheDir = URL(fileURLWithPath: cacheDirStr)
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)

        // 書類IDを決定
        let targetDocID: String
        if let dId = docId, !dId.isEmpty {
            targetDocID = dId
        } else {
            // 最新の有価証券報告書を検索
            let docs = await EdinetDiscovery.buildDocumentIndexForCode(
                code: codeTrimmed, client: client, analysisYears: 1
            )
            guard let latest = docs.first, let dId = latest["docID"] as? String else {
                printError("書類が見つかりませんでした: \(codeTrimmed)\n")
                throw ExitCode.failure
            }
            targetDocID = dId
            printError("書類ID: \(targetDocID)\n")
        }

        // XBRL ダウンロード
        guard let xbrlDir = await client.downloadDocument(targetDocID) else {
            printError("XBRLのダウンロードに失敗しました: \(targetDocID)\n")
            throw ExitCode.failure
        }

        // セクション抽出
        let targetSections = sections.isEmpty
            ? Array(xbrlSections.keys) + SegmentExtractor.specialSectionKeys
            : sections
        let parser = XBRLParser()
        var result: [String: Any] = ["docID": targetDocID, "code": codeTrimmed]
        var extracted: [String: String] = [:]
        var segmentResults: [String: SegmentResult] = [:]
        var sectionsOut: [String: Any] = [:]

        for sectionKey in targetSections {
            if let seg = SegmentExtractor.extractSpecialSection(sectionKey, xbrlDir: xbrlDir) {
                segmentResults[sectionKey] = seg
                sectionsOut[sectionKey] = seg.toDictionary()
            } else if let sectionDef = xbrlSections[sectionKey] {
                let text = parser.extractSection(in: xbrlDir, sectionName: sectionDef.title)
                extracted[sectionKey] = text ?? ""
                sectionsOut[sectionKey] = text ?? ""
            }
        }
        result["sections"] = sectionsOut

        if json {
            let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: opts),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            renderSections(docID: targetDocID, extracted: extracted, segmentResults: segmentResults)
        }
    }

    /// remote バックエンド経路。計算済みセクションを受け取り、ローカルと同じ整形で表示する。
    private func runRemote(_ remote: RemoteAPIClient) async throws {
        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)
        let result: RemoteFilingContent
        switch await remote.getFilingContent(
            code: codeTrimmed, docId: docId, sections: sections.isEmpty ? nil : sections)
        {
        case .ok(let r): result = r
        case .notFound(let m), .failure(let m): printError(m + "\n"); throw ExitCode.failure
        }

        // sections は本文（文字列）とセグメント表（辞書）の混在。ローカルと同じ型へ復元する。
        var extracted: [String: String] = [:]
        var segmentResults: [String: SegmentResult] = [:]
        for (key, value) in result.sections {
            if let text = value as? String {
                extracted[key] = text
            } else if let dict = value as? [String: Any] {
                segmentResults[key] = SegmentResult(dictionary: dict)
            }
        }

        if json {
            printJSONObject([
                "code": result.code, "docID": result.docId, "sections": result.sections,
            ])
        } else {
            renderSections(docID: result.docId, extracted: extracted, segmentResults: segmentResults)
        }
    }

    /// セクション本文・セグメント表を人間向けに整形表示する（ローカル・remote 共通）。
    private func renderSections(
        docID: String, extracted: [String: String], segmentResults: [String: SegmentResult]
    ) {
        printError("\n[書類 \(docID)]\n")
        for (key, text) in extracted.sorted(by: { $0.key < $1.key }) {
            let def = xbrlSections[key]
            let title = def?.title ?? key
            printError("\n## \(title)\n")
            if text.isEmpty {
                printError("（見つかりませんでした）\n")
            } else {
                let truncated = text.count > 2000 ? String(text.prefix(2000)) + "..." : text
                printError(truncated + "\n")
            }
        }
        for (key, seg) in segmentResults.sorted(by: { $0.key < $1.key }) {
            let title = SegmentExtractor.specialSectionTitles[key] ?? key
            printError("\n## \(title)\n")
            printSegmentResult(seg)
        }
    }

    private func printSegmentResult(_ seg: SegmentResult) {
        switch seg.method {
        case "html_table":
            for t in seg.tables {
                let period = t.period.map { "（\($0)）" } ?? ""
                printError("\n### \(t.heading)\(period)\n\(t.markdown)\n")
            }
        case "xbrl_facts":
            printError("（HTML表未検出・dimensionファクト \(seg.facts.count) 件を集計）\n")
            printSegmentFactsAsTable(seg.facts)
        default:
            printError("（見つかりませんでした）\n")
        }
    }

    private func printSegmentFactsAsTable(_ facts: [SegmentFact]) {
        guard !facts.isEmpty else { return }

        func periodOf(_ ctx: String) -> (label: String, order: Int) {
            let patterns: [(String, String, Int)] = [
                ("Prior1YearDuration",    "前期",    0),
                ("Prior1InterimDuration", "前中間期", 1),
                ("CurrentYearDuration",   "当期",    2),
                ("CurrentYTDDuration",    "当期",    2),
                ("InterimDuration",       "中間期",   3),
                ("Prior1YearInstant",     "前期末",   4),
                ("Prior1InterimInstant",  "前中間末", 5),
                ("CurrentYearInstant",    "当期末",   6),
                ("InterimInstant",        "中間末",   7),
            ]
            for (prefix, label, order) in patterns {
                if ctx.hasPrefix(prefix) { return (label, order) }
            }
            return (ctx, 99)
        }

        func memberShortName(_ m: String) -> String {
            switch m {
            case "ReportableSegmentsMember": return "計"
            case "ReconcilingItemsMember":   return "調整"
            case "CorporateSharedMember":    return "全社"
            case "NonConsolidatedMember":    return "単体"
            default:
                var n = m
                for sfx in ["ReportableSegmentsMember", "ReportabelSegmentsMember",
                             "SegmentsMember", "Member"] {
                    if n.hasSuffix(sfx) { n = String(n.dropLast(sfx.count)); break }
                }
                if n.hasSuffix("BusinessUnit") { n = String(n.dropLast("BusinessUnit".count)) }
                return n.isEmpty ? m : n
            }
        }

        func memberSortOrder(_ m: String) -> Int {
            if m == "ReportableSegmentsMember" { return 90 }
            if m.contains("Corporate")         { return 91 }
            if m.contains("Reconciling")       { return 92 }
            if m.contains("NonConsolidated")   { return 95 }
            return 0
        }

        // primary segment member: prefer OperatingSegments/BusinessSegment/ReportableSegment axis
        let segAxisKeywords = ["OperatingSegments", "BusinessSegment", "ReportableSegment",
                                "GeographicArea", "Geography", "Country", "Region"]
        func primaryMember(_ f: SegmentFact) -> String? {
            for (k, v) in f.dimensions {
                if segAxisKeywords.contains(where: { k.contains($0) }) { return v }
            }
            return f.dimensions.values.first
        }

        func fmtValue(_ v: Double, _ unit: String?) -> String {
            let u = (unit ?? "").uppercased()
            let isMonetary = u.isEmpty || u == "JPY" || u.hasPrefix("JPY")
            if isMonetary && abs(v) >= 1_000_000 {
                let m = v / 1_000_000
                return m == Double(Int(m))
                    ? String(format: "%.0f", m)
                    : String(format: "%.1f", m)
            }
            return String(format: "%.0f", v)
        }

        // Build pivot: periodLabel -> metricLabel -> member -> (value, unit)
        struct PKey: Hashable { let label: String; let order: Int }
        var memberSet = Set<String>()
        var pivot: [PKey: [String: [String: (Double, String?)]]] = [:]
        var allMetrics: [String] = []  // insertion-order unique

        for f in facts {
            guard let member = primaryMember(f) else { continue }
            let (pLabel, pOrder) = periodOf(f.contextRef)
            let pKey = PKey(label: pLabel, order: pOrder)
            let metric = f.label ?? f.tag
            memberSet.insert(member)
            if pivot[pKey] == nil { pivot[pKey] = [:] }
            if pivot[pKey]![metric] == nil {
                pivot[pKey]![metric] = [:]
                if !allMetrics.contains(metric) { allMetrics.append(metric) }
            }
            // first-write wins (prefer consolidated over non-consolidated)
            if pivot[pKey]![metric]![member] == nil {
                pivot[pKey]![metric]![member] = (f.value, f.unitRef)
            }
        }

        guard !memberSet.isEmpty, !pivot.isEmpty else {
            printError("（ファクトを表形式に変換できませんでした）\n")
            return
        }

        let sortedMembers = memberSet.sorted {
            let oa = memberSortOrder($0), ob = memberSortOrder($1)
            return oa != ob ? oa < ob : $0 < $1
        }
        let shortHeaders = sortedMembers.map { memberShortName($0) }
        let hasMonetary = facts.contains { f in
            let u = (f.unitRef ?? "").uppercased()
            return (u.isEmpty || u == "JPY" || u.hasPrefix("JPY")) && abs(f.value) >= 1_000_000
        }
        if hasMonetary { printError("（単位: 百万円）\n") }

        for pKey in pivot.keys.sorted(by: { $0.order < $1.order }) {
            guard let metrics = pivot[pKey], !metrics.isEmpty else { continue }
            printError("\n【\(pKey.label)】\n")
            let header = "| 指標 | " + shortHeaders.joined(separator: " | ") + " |"
            let sep    = "|---|" + shortHeaders.map { _ in "---:" }.joined(separator: "|") + "|"
            printError(header + "\n" + sep + "\n")
            for metric in allMetrics {
                guard let vals = metrics[metric] else { continue }
                let cells = sortedMembers.map { m -> String in
                    guard let (v, u) = vals[m] else { return "-" }
                    return fmtValue(v, u)
                }
                printError("| \(metric) | " + cells.joined(separator: " | ") + " |\n")
            }
        }
    }
}
