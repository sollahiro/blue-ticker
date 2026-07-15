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
        let remote = try await RemoteBackend.client()
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

        let remote = try await RemoteBackend.client()
        let codeTrimmed = code.trimmingCharacters(in: .whitespaces)
        let result: RemoteFilingContent
        switch await remote.getFilingContent(
            code: codeTrimmed, docId: docId, sections: sections.isEmpty ? nil : sections)
        {
        case .ok(let r): result = r
        case .notFound(let m), .failure(let m): printError(m + "\n"); throw ExitCode.failure
        }

        // sections は本文（文字列）とセグメント表（辞書）の混在。remote 共通の型へ復元する。
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
            FilingRendering.renderSections(docID: result.docId, extracted: extracted, segmentResults: segmentResults)
        }
    }
}
