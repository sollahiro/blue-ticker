import Foundation
import Testing
@testable import BlueTickerCore

enum PocJevExport {
    static let noneOfThese = "none_of_these"
    static let maxTagsPerDoc = 40

    static let epsCodes: Set<String> = [
        "1840", "2425", "3306", "3652", "3663", "3895", "3907", "3920",
        "5367", "5423", "5609", "6194", "6485", "8595", "8613", "9272", "9344", "9969",
    ]
    static let salesCodes: Set<String> = ["2433", "2156"]
    static let massMissing: [(code: String, docID: String)] = [
        ("5367", "S100Y9NY"),
        ("4381", "S100YDPE"),
        ("9250", "S100XNEI"),
        ("3681", "S100Y1NL"),
        ("6085", "S100Y7A6"),
    ]

    static func run() async throws {
        try FileManager.default.createDirectory(at: PocJevIO.outDir, withIntermediateDirectories: true)
        let financials = try PocJevIO.loadJSONArray("financials.json")
        let breakdowns = try PocJevIO.loadJSONArray("breakdowns.json")

        let apiKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"]
        let cacheDir = PocJevIO.repoRoot().appendingPathComponent("tmp_cache/edinet")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheStore = EdinetCacheStore(cacheDir: cacheDir)
        var objectStore: (any XbrlObjectStoring)?
        if let cfg = R2StorageConfig.resolveXbrlFromEnvironment() {
            objectStore = GetOnlyXbrlStore(inner: R2XbrlObjectStore(config: cfg))
        }
        let client = EdinetAPIClient(
            apiKey: apiKey, cacheStore: cacheStore, xbrlObjectStore: objectStore)

        var needed = Set<String>()
        for row in financials {
            if let latest = row["latest"] as? [String: Any], let doc = latest["doc_id"] as? String {
                needed.insert(doc)
            }
        }
        for row in breakdowns {
            if let doc = row["doc_id"] as? String { needed.insert(doc) }
        }
        for m in massMissing { needed.insert(m.docID) }

        var downloaded: [String: URL] = [:]
        var downloadFailures: [String] = []
        await withTaskGroup(of: (String, URL?).self) { group in
            for docID in needed.sorted() {
                group.addTask {
                    let url = await client.downloadDocument(docID, saveDir: cacheDir)
                    return (docID, url)
                }
            }
            for await (docID, url) in group {
                if let url {
                    downloaded[docID] = url
                } else {
                    downloadFailures.append(docID)
                }
            }
        }

        var tagRows: [[String: Any]] = []
        var skippedTags: [[String: String]] = []
        var diagnoses: [String] = []

        for row in financials {
            guard let code = row["code"] as? String,
                  let latest = row["latest"] as? [String: Any],
                  let docID = latest["doc_id"] as? String
            else { continue }
            let fyEnd = (latest["fy_end"] as? String) ?? ""
            let missing = missingCanonicalFields(latest)
            let isEPS = epsCodes.contains(code)
            let isSales = salesCodes.contains(code)
            let isMass = massMissing.contains { $0.code == code && $0.docID == docID }
            guard isEPS || isSales || isMass else { continue }

            var missingFields = missing
            if isEPS, !missingFields.contains("eps") { missingFields.insert("eps", at: 0) }
            if isSales, !missingFields.contains("sales") { missingFields.insert("sales", at: 0) }
            if missingFields.isEmpty { missingFields = isSales ? ["sales"] : ["eps"] }

            guard let xbrlDir = downloaded[docID] else {
                skippedTags.append(["code": code, "doc_id": docID, "reason": "xbrl_download_failed"])
                continue
            }

            let produced = exportTagCandidates(
                code: code, docID: docID, fyEnd: fyEnd,
                missingFields: missingFields, xbrlDir: xbrlDir)
            tagRows.append(contentsOf: produced)

            if isMass {
                let prior = row["prior"] as? [String: Any]
                diagnoses.append(diagnoseMassMissing(
                    code: code, docID: docID, fyEnd: fyEnd,
                    latest: latest, prior: prior, xbrlDir: xbrlDir, index: nil))
            }
        }

        var tableRows: [[String: Any]] = []
        var cellRows: [[String: Any]] = []
        var tokenRows: [[String: Any]] = []
        var skippedTables: [[String: String]] = []

        for row in breakdowns {
            guard let code = row["code"] as? String,
                  let docID = row["doc_id"] as? String
            else { continue }
            let fyEnd = (row["fy_end"] as? String) ?? ""
            guard let xbrlDir = downloaded[docID] else {
                skippedTables.append(["code": code, "doc_id": docID, "reason": "xbrl_download_failed"])
                continue
            }
            let storedRows = (row["rows"] as? [[String: Any]]) ?? []
            let storedUnit = row["stored_unit"] as? String
            let denominator = (row["denominator"] as? Double)
                ?? (row["denominator"] as? NSNumber)?.doubleValue
            let sales = denominator ?? 1
            let exported = exportTablesAndCells(
                code: code, docID: docID, fyEnd: fyEnd, xbrlDir: xbrlDir,
                consolidatedSales: sales, storedRows: storedRows, storedUnit: storedUnit)
            if exported.tables.isEmpty && exported.cells.isEmpty {
                skippedTables.append([
                    "code": code, "doc_id": docID,
                    "reason": exported.skipReason ?? "no_candidate_tables",
                ])
            }
            tableRows.append(contentsOf: exported.tables)
            cellRows.append(contentsOf: exported.cells)
            if let token = exported.tokens { tokenRows.append(token) }
        }

        let tagURL = try PocJevIO.writeJSONL(tagRows, to: "tag_classify.jsonl")
        let tableURL = try PocJevIO.writeJSONL(tableRows, to: "table_select.jsonl")
        let cellURL = try PocJevIO.writeJSONL(cellRows, to: "cell_select.jsonl")
        let tokenURL = try PocJevIO.writeJSONL(tokenRows, to: "token_sizes.json")
        _ = tokenURL

        let diagnosis = diagnoses.joined(separator: "\n\n")
        _ = try PocJevIO.writeText(diagnosis + "\n", to: "mass_missing_diagnosis.md")

        let report: [String: Any] = [
            "tag_classify_lines": tagRows.count,
            "tag_classify_docs": Set(tagRows.compactMap { $0["doc_id"] as? String }).count,
            "table_select_lines": tableRows.count,
            "table_select_docs": Set(tableRows.compactMap { $0["doc_id"] as? String }).count,
            "cell_select_lines": cellRows.count,
            "cell_select_docs": Set(cellRows.compactMap { $0["doc_id"] as? String }).count,
            "download_failures": downloadFailures.sorted(),
            "skipped_tags": skippedTags,
            "skipped_tables": skippedTables,
            "paths": [
                tagURL.path, tableURL.path, cellURL.path,
            ],
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _ = try PocJevIO.writeText(
            String(data: reportData, encoding: .utf8) ?? "{}", to: "export_report.json")
        PocJevIO.copyToArtifacts()
        print("PocJev export done: tags=\(tagRows.count) tables=\(tableRows.count) cells=\(cellRows.count)")
    }

    static func missingCanonicalFields(_ year: [String: Any]) -> [String] {
        PocJevMappedTags.canonicalRawKeys.filter { key in
            year[key] == nil || year[key] is NSNull
        }
    }

    static func exportTagCandidates(
        code: String, docID: String, fyEnd: String,
        missingFields: [String], xbrlDir: URL
    ) -> [[String: Any]] {
        let index = XBRLUtils.collectAllNumericFacts(in: xbrlDir, nilAsZero: false)
        let ja = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        let en = PocJevLabels.englishLabels(in: xbrlDir)
        let qnames = PocJevLabels.qnames(in: xbrlDir)
        let parents = PocJevLabels.calcParents(in: xbrlDir, jaLabels: ja)
        let facts = PocJevFacts.currentPeriodFacts(from: index)

        struct Cand {
            var score: Int
            var row: [String: Any]
        }
        var cands: [Cand] = []
        for (tag, fact) in facts {
            guard !PocJevMappedTags.all.contains(tag) else { continue }
            guard !tag.hasSuffix("Abstract") else { continue }
            let jaLabel = fact.label ?? ja[tag] ?? ""
            let enLabel = en[tag] ?? ""
            let parent = parents[tag]
            let parentQ = parent.map { qnames[$0.parent] ?? $0.parent } ?? ""
            let parentJa = parent?.label ?? ""
            let score = PocJevScoring.score(
                tag: tag, ja: jaLabel, en: enLabel,
                parent: parentQ + parentJa, missing: missingFields, unit: fact.unitRef)
            var row: [String: Any] = [
                "code": code,
                "doc_id": docID,
                "fy_end": fyEnd,
                "missing_fields": missingFields,
                "tag": qnames[tag] ?? tag,
                "ja_label": jaLabel,
                "en_label": enLabel,
                "calc_parent": parent == nil ? NSNull() : "\(parentQ) \(parentJa)".trimmingCharacters(in: .whitespaces),
                "context_id": fact.contextRef,
                "unit": fact.unitRef ?? NSNull(),
                "decimals": fact.decimals ?? NSNull(),
                "value": fact.value,
                "choices": missingFields + [noneOfThese],
            ]
            if enLabel.isEmpty { row["en_label"] = NSNull() }
            cands.append(Cand(score: score, row: row))
        }
        cands.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lv = (lhs.row["value"] as? Double).map(abs) ?? 0
            let rv = (rhs.row["value"] as? Double).map(abs) ?? 0
            return lv > rv
        }
        return Array(cands.prefix(maxTagsPerDoc)).map(\.row)
    }

    struct TableExport {
        var tables: [[String: Any]]
        var cells: [[String: Any]]
        var tokens: [String: Any]?
        var skipReason: String?
    }

    static func exportTablesAndCells(
        code: String, docID: String, fyEnd: String, xbrlDir: URL,
        consolidatedSales: Double, storedRows: [[String: Any]], storedUnit: String?
    ) -> TableExport {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)
        var tables = segments.tables
        if tables.first?.heading != BreakdownExtractor.revenueRecognitionHeading {
            let rr = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: xbrlDir)
            if !rr.tables.isEmpty { tables = rr.tables }
        }
        guard !tables.isEmpty else {
            return TableExport(tables: [], cells: [], tokens: nil, skipReason: "extractor_returned_no_tables")
        }

        let promptAll = BreakdownExtractor.llmUserPrompt(tables: tables, consolidatedSales: consolidatedSales)
        let hasCurrent = tables.contains { $0.period == "当期" }
        let droppedPrior = hasCurrent ? tables.filter { $0.period != "前期" } : tables
        let promptCurrent = BreakdownExtractor.llmUserPrompt(
            tables: droppedPrior, consolidatedSales: consolidatedSales)
        let tokens: [String: Any] = [
            "code": code,
            "doc_id": docID,
            "fy_end": fyEnd,
            "table_count": tables.count,
            "table_count_after_drop_prior": droppedPrior.count,
            "prompt_all": PocJevTokens.approx(chars: promptAll.count),
            "prompt_drop_prior_if_current": PocJevTokens.approx(chars: promptCurrent.count),
            "saved_chars": max(0, promptAll.count - promptCurrent.count),
        ]

        let indices = tables.indices.map(String.init) + [noneOfThese]
        var tableJSON: [[String: Any]] = []
        for (i, table) in tables.enumerated() {
            tableJSON.append([
                "code": code,
                "doc_id": docID,
                "fy_end": fyEnd,
                "table_index": i,
                "period": table.period ?? NSNull(),
                "heading": table.heading,
                "table_markdown": table.markdown,
                "unit_caption": table.unitCaption ?? NSNull(),
                "choices": indices,
                "prompt_chars_all": promptAll.count,
                "prompt_tokens_all_div4": max(1, (promptAll.count + 3) / 4),
                "prompt_chars_drop_prior": promptCurrent.count,
                "prompt_tokens_drop_prior_div4": max(1, (promptCurrent.count + 3) / 4),
            ])
        }

        let currentTables: [(Int, BreakdownTable)] = {
            let marked = tables.enumerated().filter { $0.element.period == "当期" || $0.element.period == "比較" }
            if !marked.isEmpty { return marked.map { ($0.offset, $0.element) } }
            return tables.enumerated().map { ($0.offset, $0.element) }
        }()

        var cellJSON: [[String: Any]] = []
        for stored in storedRows {
            let label = (stored["label_raw"] as? String) ?? (stored["label"] as? String) ?? ""
            var choices: [[String: Any]] = []
            for (tableIndex, table) in currentTables {
                let grid = BreakdownExtractor.markdownToGrid(table.markdown)
                let unitHint = table.unitCaption
                    ?? BreakdownExtractor.parseUnitCaption(table.markdown)
                    ?? ""
                let headerRows = grid.prefix { row in
                    !row.contains { XBRLUtils.parseHtmlNumber($0) != nil }
                }
                for (r, row) in grid.enumerated() {
                    let rowHeader = row.first ?? ""
                    for (c, cell) in row.enumerated() where c > 0 {
                        guard let parsed = XBRLUtils.parseHtmlNumber(cell) else { continue }
                        var colHeaderParts: [String] = []
                        for header in headerRows where c < header.count {
                            let h = header[c].trimmingCharacters(in: .whitespaces)
                            if !h.isEmpty { colHeaderParts.append(h) }
                        }
                        let colHeader = colHeaderParts.joined(separator: " / ")
                        choices.append([
                            "id": "t\(tableIndex)_r\(r)_c\(c)",
                            "table_index": tableIndex,
                            "row_header": rowHeader,
                            "column_header": colHeader,
                            "raw_text": cell,
                            "parsed_number": parsed,
                            "unit_hint": unitHint,
                        ])
                    }
                }
            }
            var choiceList: [Any] = choices
            choiceList.append(noneOfThese)
            cellJSON.append([
                "code": code,
                "doc_id": docID,
                "fy_end": fyEnd,
                "stored_label_raw": label,
                "stored_label": stored["label"] ?? label,
                "stored_amount_yen": stored["amount"] ?? NSNull(),
                "stored_profit_yen": stored["profit"] ?? NSNull(),
                "stored_row_kind": stored["row_kind"] ?? NSNull(),
                "stored_unit": storedUnit ?? NSNull(),
                "choices": choiceList,
            ])
        }
        return TableExport(tables: tableJSON, cells: cellJSON, tokens: tokens, skipReason: nil)
    }

    static func diagnoseMassMissing(
        code: String, docID: String, fyEnd: String,
        latest: [String: Any], prior: [String: Any]?, xbrlDir: URL, index: XbrlFactIndex?
    ) -> String {
        let facts = index ?? XBRLUtils.collectAllNumericFacts(in: xbrlDir, nilAsZero: false)
        let census = PocJevFacts.contextCensus(facts)
        let missingLatest = missingCanonicalFields(latest)
        let missingPrior = prior.map { missingCanonicalFields($0) } ?? []
        let newlyMissing = missingLatest.filter { !missingPrior.contains($0) }
        let na = latest["net_assets"] as? Double
        var lines: [String] = []
        lines.append("## \(code) \(docID) fy_end=\(fyEnd)")
        lines.append("- Neon latest empty canonical: \(missingLatest.joined(separator: ", "))")
        if let prior {
            let pfy = prior["fy_end"] as? String ?? ""
            lines.append("- Neon prior (\(pfy)) empty canonical: \(missingPrior.joined(separator: ", "))")
            lines.append("- Newly empty vs prior: \(newlyMissing.joined(separator: ", "))")
        }
        if let na {
            lines.append("- net_assets latest = \(na) (\(na > 0 ? "positive" : "non-positive"))")
        }
        lines.append("- XBRL current context census: consolidated=\(census["consolidated_current"] ?? 0) pure_nc=\(census["pure_nc_current"] ?? 0) other=\(census["other"] ?? 0)")

        let probe: [(String, [String])] = [
            ("sales", Xbrl.netSalesTags),
            ("cash_equivalents", Xbrl.cashEquivalentsTags),
            ("ppe_total", Xbrl.ppeTotalJGAAPDirectTags + Xbrl.ppeTotalIFRSDirectTags),
            ("accounts_receivable", Xbrl.accountsReceivableJGAAPTags + Xbrl.accountsReceivableIFRSTags),
            ("accounts_payable", Xbrl.accountsPayableJGAAPTags + Xbrl.accountsPayableIFRSTags),
            ("inventory", Xbrl.inventoryJGAAPTags + Xbrl.inventoryIFRSTags),
            ("eps", Xbrl.basicEpsTags),
            ("employees", Xbrl.employeeTags),
        ]
        for (field, tags) in probe {
            var hits: [String] = []
            for tag in tags {
                guard let ctxMap = facts[tag] else { continue }
                for (ctx, fact) in ctxMap.sorted(by: { $0.key < $1.key }) {
                    let kind: String
                    if PocJevFacts.isCurrentConsolidated(ctx) { kind = "cons_current" }
                    else if PocJevFacts.isCurrentPureNonConsolidated(ctx) { kind = "nc_current" }
                    else { kind = "other" }
                    hits.append("\(tag) ctx=\(ctx) kind=\(kind) value=\(fact.value)")
                }
            }
            if hits.isEmpty {
                lines.append("- \(field): no mapped tags in this instance")
            } else {
                lines.append("- \(field) facts:")
                for h in hits.prefix(8) { lines.append("  - \(h)") }
            }
        }

        if let na, na <= 0 {
            lines.append("- Note: IndividualAnalyzer leaves `roe` / `net_de` (and ROE waterfall effects) null when equity ≤ 0. That is a derived-field rule, not a missing XBRL fact.")
        }
        if census["consolidated_current", default: 0] > 0, census["pure_nc_current", default: 0] > 0 {
            lines.append("- Note: this filing has both consolidated current and pure non-consolidated current contexts. FieldSet builders do not merge NC when any cons+NC pair exists (`hasNonConsolidatedContexts`). Statement overlay then copies non-zero statement lines; tags that are not statement lines stay empty if they live only on NC contexts.")
        }
        if census["consolidated_current", default: 0] == 0, census["pure_nc_current", default: 0] > 0 {
            lines.append("- Note: no consolidated current context; facts sit on `*_NonConsolidatedMember`. This matches the 5367 / S100Y9NY comment in StatementFinancialsResolver (non-consolidated-only overlay).")
        }
        return lines.joined(separator: "\n")
    }
}

struct PocJevExportTests {
    @Test func committedJsonlHasNoneOfTheseWhenPresent() throws {
        let names = ["tag_classify.jsonl", "table_select.jsonl", "cell_select.jsonl"]
        for name in names {
            let url = PocJevIO.outDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
            if lines.isEmpty { continue }
            for line in lines.prefix(20) {
                let data = Data(line.utf8)
                let obj = try JSONSerialization.jsonObject(with: data)
                guard let dict = obj as? [String: Any], let choices = dict["choices"] as? [Any] else {
                    Issue.record("\(name) line missing choices")
                    continue
                }
                let last = choices.last as? String
                #expect(last == "none_of_these" || (choices.last as? [String: Any])?["id"] as? String == "none_of_these")
            }
        }
    }

    @Test func exportCandidatesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BLT_POC_JEV_RUN"] == "1" else { return }
        try await PocJevExport.run()
        for name in ["tag_classify.jsonl", "table_select.jsonl", "cell_select.jsonl"] {
            let url = PocJevIO.outDir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
