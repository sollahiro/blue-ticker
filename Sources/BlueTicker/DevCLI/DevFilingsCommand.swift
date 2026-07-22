import ArgumentParser
import Foundation

/// `ticker filings` のローカル版（開発用。EDINET を直接叩く）。
struct DevFilingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filings",
        abstract: "銘柄の有価証券報告書一覧を表示します（ローカル）"
    )

    @Argument(help: "銘柄コード")
    var code: String

    @Option(name: .shortAndLong, help: "取得年数")
    var years: Int = Api.filingsDefaultYears

    @Flag(name: .long, help: "JSON 形式で出力")
    var json = false

    func run() async throws {
        let client = try await EdinetClientLoader.make().client
        let service = FilingService(edinetClient: client)

        let docs = await service.searchFilings(
            code: code,
            maxYears: years,
            docTypes: Array(Api.filingsDisplayDocTypes),
            maxDocuments: Api.filingsCliMaxDocuments
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
}

/// `ticker filing` のローカル版（開発用。EDINET から XBRL を取得し in-process で抽出する）。
struct DevFilingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filing",
        abstract: "有価証券報告書のセクション内容を抽出します（ローカル）"
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
        let validSections = Set(xbrlSections.keys).union(BreakdownExtractor.specialSectionKeys)
        let unknown = sections.filter { !validSections.contains($0) }
        guard unknown.isEmpty else {
            printError("エラー: 不明なセクション: \(unknown.joined(separator: ", "))。有効: \(validSections.sorted().joined(separator: ", "))\n")
            throw ExitCode.failure
        }

        let client = try await EdinetClientLoader.make().client
        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)

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
            ? Array(xbrlSections.keys) + BreakdownExtractor.specialSectionKeys
            : sections
        let parser = XBRLParser()
        var result: [String: Any] = ["docID": targetDocID, "code": codeTrimmed]
        var extracted: [String: String] = [:]
        var extractedBreakdowns: [String: ExtractedBreakdown] = [:]
        var sectionsOut: [String: Any] = [:]

        for sectionKey in targetSections {
            if let seg = BreakdownExtractor.extractSpecialSection(sectionKey, xbrlDir: xbrlDir) {
                extractedBreakdowns[sectionKey] = seg
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
            FilingRendering.renderSections(docID: targetDocID, extracted: extracted, extractedBreakdowns: extractedBreakdowns)
        }
    }
}
