import Foundation
import Testing
@testable import BlueTickerCore

enum PocJevExport {
    static let noneOfThese = "none_of_these"
    static let yearPattern = try! NSRegularExpression(
        pattern: #"(?:20\d{2}|１９\d{2}|２０\d{2})(?:\s*年(?:度|3月期|3月末|3月31日|３月期)?|年度|年)"#)

    static func run() async throws {
        try FileManager.default.createDirectory(at: PocJevIO.outDir, withIntermediateDirectories: true)

        let segmentTargets = try PocJevIO.loadJSONArray("breakdowns_segment_info.json")
        let geoTargets = try PocJevIO.loadJSONArray("breakdowns_geography.json")
        let rrTargets = try PocJevIO.loadJSONArray("breakdowns_revenue_recognition.json")
        let noteTargets = try PocJevIO.loadJSONArray("targets_notes.json")

        var needed = Set<String>()
        for row in segmentTargets + geoTargets + rrTargets + noteTargets {
            if let doc = row["doc_id"] as? String { needed.insert(doc) }
        }

        let cacheDir = PocJevIO.repoRoot().appendingPathComponent("tmp_cache/edinet")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheStore = EdinetCacheStore(cacheDir: cacheDir)
        var objectStore: (any XbrlObjectStoring)?
        if let cfg = R2StorageConfig.resolveXbrlFromEnvironment() {
            objectStore = GetOnlyXbrlStore(inner: R2XbrlObjectStore(config: cfg))
        }
        let client = EdinetAPIClient(
            apiKey: ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"],
            cacheStore: cacheStore,
            xbrlObjectStore: objectStore)

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

        var periodAudit: [[String: Any]] = []
        func extract(
            axis: String, xbrlDir: URL
        ) -> [BreakdownTable] {
            switch axis {
            case "segment_info":
                return BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir).tables
            case "geography":
                return BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir).tables
            case "revenue_recognition":
                return BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: xbrlDir).tables
            default:
                return []
            }
        }

        func exportAxis(
            axis: String, targets: [[String: Any]]
        ) -> (tables: [[String: Any]], cells: [[String: Any]], usable: [[String: Any]]) {
            var tableRows: [[String: Any]] = []
            var cellRows: [[String: Any]] = []
            var usableRows: [[String: Any]] = []
            for row in targets {
                guard let code = row["code"] as? String, let docID = row["doc_id"] as? String else {
                    continue
                }
                let fyEnd = (row["fy_end"] as? String) ?? ""
                guard let xbrlDir = downloaded[docID] else { continue }
                let tables = extract(axis: axis, xbrlDir: xbrlDir)
                let sales = PocJevJSON.double(row, "denominator") ?? 1
                let exported = exportTablesAndCells(
                    axis: axis, code: code, docID: docID, fyEnd: fyEnd, tables: tables,
                    consolidatedSales: sales,
                    storedRows: (row["rows"] as? [[String: Any]]) ?? [],
                    storedUnit: row["stored_unit"] as? String,
                    storedTableIndex: row["stored_table_index"] as? String
                        ?? (row["stored_table_index"] as? NSNumber)?.stringValue,
                    storedPeriodColumn: row["stored_period_column"] as? String,
                    neonBucket: (row["bucket"] as? NSNumber)?.intValue ?? row["bucket"] as? Int,
                    neonReason: row["reason"] as? String,
                    neonLayout: row["layout"] as? String)
                tableRows.append(contentsOf: exported.tables)
                cellRows.append(contentsOf: exported.cells)
                usableRows.append(exported.usable)
                periodAudit.append(exported.audit)
            }
            return (tableRows, cellRows, usableRows)
        }

        let seg = exportAxis(axis: "segment_info", targets: segmentTargets)
        let geo = exportAxis(axis: "geography", targets: geoTargets)
        let rr = exportAxis(axis: "revenue_recognition", targets: rrTargets)

        var noteTableRows: [[String: Any]] = []
        var noteCellRows: [[String: Any]] = []
        for row in noteTargets {
            guard let code = row["code"] as? String,
                  let docID = row["doc_id"] as? String,
                  let noteType = row["note_type"] as? String,
                  let xbrlDir = downloaded[docID]
            else { continue }
            let fyEnd = (row["fy_end"] as? String) ?? ""
            let tables = extractNoteTables(noteType: noteType, xbrlDir: xbrlDir)
            let exported = exportTablesAndCells(
                axis: "notes:\(noteType)", code: code, docID: docID, fyEnd: fyEnd, tables: tables,
                consolidatedSales: 1, storedRows: [], storedUnit: nil,
                storedTableIndex: nil, storedPeriodColumn: nil,
                neonBucket: nil, neonReason: nil, neonLayout: nil)
            for var t in exported.tables {
                t["note_type"] = noteType
                t["task"] = "table_select"
                noteTableRows.append(t)
            }
            // notes cell_select: one item per numeric row header in current-year tables
            let current = currentYearTables(tables)
            var seen = Set<String>()
            for (tableIndex, table) in current {
                let grid = BreakdownExtractor.markdownToGrid(table.markdown)
                for rowCells in grid {
                    let label = rowCells.first ?? ""
                    guard !label.isEmpty, !seen.contains(label) else { continue }
                    guard rowCells.contains(where: { XBRLUtils.parseHtmlNumber($0) != nil }) else {
                        continue
                    }
                    seen.insert(label)
                    noteCellRows.append(contentsOf: cellRow(
                        axis: "notes:\(noteType)", code: code, docID: docID, fyEnd: fyEnd,
                        stored: [
                            "label_raw": label, "label": label,
                            "amount": NSNull(), "profit": NSNull(), "row_kind": NSNull(),
                        ],
                        storedUnit: table.unitCaption, currentTables: current, extra: [
                            "note_type": noteType,
                        ]))
                }
            }
            periodAudit.append(exported.audit)
        }

        let paths = [
            try PocJevIO.writeJSONL(seg.tables, to: "table_select_segment_info.jsonl"),
            try PocJevIO.writeJSONL(geo.tables, to: "table_select_geography.jsonl"),
            try PocJevIO.writeJSONL(seg.cells, to: "cell_select_segment_info.jsonl"),
            try PocJevIO.writeJSONL(geo.cells, to: "cell_select_geography.jsonl"),
            try PocJevIO.writeJSONL(seg.usable, to: "usable_segment_info.jsonl"),
            try PocJevIO.writeJSONL(geo.usable, to: "usable_geography.jsonl"),
            try PocJevIO.writeJSONL(rr.usable, to: "usable_revenue_recognition.jsonl"),
            try PocJevIO.writeJSONL(noteTableRows, to: "table_select_notes.jsonl"),
            try PocJevIO.writeJSONL(noteCellRows, to: "cell_select_notes.jsonl"),
            try PocJevIO.writeJSONL(periodAudit, to: "period_audit_downloaded.jsonl"),
        ]

        func countDocs(_ rows: [[String: Any]]) -> Int {
            Set(rows.compactMap { $0["doc_id"] as? String }).count
        }
        let report: [String: Any] = [
            "download_failures": downloadFailures.sorted(),
            "downloaded_docs": downloaded.count,
            "table_select_segment_info": ["lines": seg.tables.count, "docs": countDocs(seg.tables)],
            "table_select_geography": ["lines": geo.tables.count, "docs": countDocs(geo.tables)],
            "cell_select_segment_info": ["lines": seg.cells.count, "docs": countDocs(seg.cells)],
            "cell_select_geography": ["lines": geo.cells.count, "docs": countDocs(geo.cells)],
            "usable_segment_info": ["lines": seg.usable.count, "docs": countDocs(seg.usable)],
            "usable_geography": ["lines": geo.usable.count, "docs": countDocs(geo.usable)],
            "usable_revenue_recognition": ["lines": rr.usable.count, "docs": countDocs(rr.usable)],
            "table_select_notes": ["lines": noteTableRows.count, "docs": countDocs(noteTableRows)],
            "cell_select_notes": ["lines": noteCellRows.count, "docs": countDocs(noteCellRows)],
            "paths": paths.map(\.path),
        ]
        _ = try PocJevIO.writeJSON(report, to: "export_report.json")
        PocJevIO.copyToArtifacts()
        print("PocJev v2 export done docs=\(downloaded.count) fail=\(downloadFailures.count)")
    }

    // MARK: - period classification (mirrors BreakdownExtractor.detectPeriodFromGrid)

    static func classifyTable(_ table: BreakdownTable, fyEnd: String) -> (source: String, gridPeriod: String?) {
        let grid = BreakdownExtractor.markdownToGrid(table.markdown)
        let gridPeriod = BreakdownExtractor.detectPeriodFromGrid(grid)
        if gridPeriod == "比較" { return ("explicit_compare_two_columns", gridPeriod) }
        if gridPeriod == "当期" { return ("explicit_grid_label", gridPeriod) }
        if gridPeriod == "前期" { return ("explicit_grid_prior", gridPeriod) }
        let head = grid.prefix(3).flatMap { $0 }.joined()
        let fyHit: Bool = {
            if yearPattern.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil {
                return true
            }
            let y = String(fyEnd.prefix(4))
            return y.count == 4 && head.contains(y)
        }()
        if table.period == "当期" || table.period == "比較" {
            return (fyHit ? "heuristic_year_header" : "heuristic_unlabeled", gridPeriod)
        }
        if table.period == "前期" {
            return (fyHit ? "heuristic_year_header_prior" : "heuristic_unlabeled_prior", gridPeriod)
        }
        return ("unlabeled", nil)
    }

    static func currentYearTables(_ tables: [BreakdownTable]) -> [(Int, BreakdownTable)] {
        let marked = tables.enumerated().filter {
            $0.element.period == "当期" || $0.element.period == "比較"
        }
        if !marked.isEmpty { return marked.map { ($0.offset, $0.element) } }
        return []
    }

    static func existingAnswer(tables: [BreakdownTable]) -> (answer: String, unique: Bool, indices: [Int], reason: String) {
        let current = currentYearTables(tables)
        if current.isEmpty {
            return (noneOfThese, true, [], "no_current_year_table")
        }
        let currentOnly = current.filter { $0.1.period == "当期" }
        if currentOnly.count == 1 {
            return (String(currentOnly[0].0), true, current.map(\.0), "unique_当期_table")
        }
        if currentOnly.isEmpty, current.count == 1, current[0].1.period == "比較" {
            return (String(current[0].0), true, current.map(\.0), "unique_比較_table")
        }
        // Multiple current-year tables: last 当期 (ordering heuristic), else last 比較.
        let chosen = currentOnly.last ?? current.last!
        let reason = currentOnly.count > 1 ? "last_of_multiple_当期" : "last_of_multiple_current"
        return (String(chosen.0), false, current.map(\.0), reason)
    }

    struct AxisExport {
        var tables: [[String: Any]]
        var cells: [[String: Any]]
        var usable: [String: Any]
        var audit: [String: Any]
    }

    static func exportTablesAndCells(
        axis: String, code: String, docID: String, fyEnd: String, tables: [BreakdownTable],
        consolidatedSales: Double, storedRows: [[String: Any]], storedUnit: String?,
        storedTableIndex: String?, storedPeriodColumn: String?,
        neonBucket: Int?, neonReason: String?, neonLayout: String?
    ) -> AxisExport {
        let promptAll = tables.isEmpty
            ? "" : BreakdownExtractor.llmUserPrompt(tables: tables, consolidatedSales: consolidatedSales)
        let hasCurrent = tables.contains { $0.period == "当期" }
        let droppedPrior = hasCurrent ? tables.filter { $0.period != "前期" } : tables
        let promptCurrent = tables.isEmpty
            ? ""
            : BreakdownExtractor.llmUserPrompt(tables: droppedPrior, consolidatedSales: consolidatedSales)

        let existing = existingAnswer(tables: tables)
        let indices = tables.indices.map(String.init) + [noneOfThese]
        var tableJSON: [[String: Any]] = []
        var tableSources: [[String: Any]] = []
        for (i, table) in tables.enumerated() {
            let classified = classifyTable(table, fyEnd: fyEnd)
            tableSources.append([
                "table_index": i,
                "assigned_period": table.period ?? NSNull(),
                "grid_period": classified.gridPeriod ?? NSNull(),
                "source": classified.source,
                "heading": table.heading,
            ])
            tableJSON.append([
                "axis": axis,
                "code": code,
                "doc_id": docID,
                "fy_end": fyEnd,
                "table_index": i,
                "period": table.period ?? NSNull(),
                "heading": table.heading,
                "table_markdown": table.markdown,
                "unit_caption": table.unitCaption ?? NSNull(),
                "choices": indices,
                "existing_answer": existing.answer,
                "existing_answer_unique": existing.unique,
                "existing_answer_reason": existing.reason,
                "existing_answer_indices": existing.indices,
                "existing_stored_llm_table_index": storedTableIndex ?? NSNull(),
                "existing_stored_llm_period_column": storedPeriodColumn ?? NSNull(),
                "period_source": classified.source,
                "grid_period": classified.gridPeriod ?? NSNull(),
                "prompt_chars_all": promptAll.count,
                "prompt_tokens_all_div4": max(1, (promptAll.count + 3) / 4),
                "prompt_chars_drop_prior": promptCurrent.count,
                "prompt_tokens_drop_prior_div4": max(1, (promptCurrent.count + 3) / 4),
            ])
        }

        let current = currentYearTables(tables)
        var cellJSON: [[String: Any]] = []
        for stored in storedRows {
            cellJSON.append(contentsOf: cellRow(
                axis: axis, code: code, docID: docID, fyEnd: fyEnd,
                stored: stored, storedUnit: storedUnit, currentTables: current, extra: [:]))
        }

        var tablePreviews: [[String: Any]] = []
        for (i, table) in tables.enumerated() {
            tablePreviews.append([
                "table_index": i,
                "period": table.period ?? NSNull(),
                "heading": table.heading,
                "unit_caption": table.unitCaption ?? NSNull(),
                "markdown_head": String(table.markdown.prefix(400)),
            ])
        }
        let usable: [String: Any] = [
            "task": "usable_current_year_table",
            "axis": axis,
            "code": code,
            "doc_id": docID,
            "fy_end": fyEnd,
            "choices": indices,
            "tables": tablePreviews,
            "existing_answer": existing.answer,
            "existing_answer_unique": existing.unique,
            "existing_answer_reason": existing.reason,
            "existing_answer_indices": existing.indices,
            "existing_stored_llm_table_index": storedTableIndex ?? NSNull(),
            "existing_stored_llm_period_column": storedPeriodColumn ?? NSNull(),
            "layout_neon": neonLayout ?? NSNull(),
            "prompt_chars_all": promptAll.count,
            "prompt_tokens_all_div4": max(1, (promptAll.count + 3) / 4),
            "prompt_chars_drop_prior": promptCurrent.count,
            "prompt_tokens_drop_prior_div4": max(1, (promptCurrent.count + 3) / 4),
        ]

        let currentSources = tableSources.compactMap { src -> String? in
            let p = src["assigned_period"] as? String
            guard p == "当期" || p == "比較" else { return nil }
            return src["source"] as? String
        }
        let bucket: Int
        let reason: String
        if currentSources.contains(where: { $0.hasPrefix("explicit") }) {
            bucket = 1
            reason = "explicit_period_label"
        } else if !currentSources.isEmpty {
            bucket = 2
            reason = currentSources.contains("heuristic_year_header")
                ? "heuristic_year_header" : "heuristic_unlabeled"
        } else if !tables.isEmpty {
            bucket = 3
            reason = "no_current_year_table"
        } else {
            bucket = 3
            reason = "axis_empty"
        }
        let hasCompare = tables.contains { $0.period == "比較" }
        let hasPrior = tables.contains { $0.period == "前期" }
        let hasCurr = tables.contains { $0.period == "当期" }
        let layout: String
        if hasCompare && (hasPrior || hasCurr) { layout = "compare_and_separate" }
        else if hasCompare { layout = "one_table_two_columns" }
        else if hasPrior && hasCurr { layout = "separate_tables" }
        else if hasCurr { layout = "current_only" }
        else if hasPrior { layout = "prior_only" }
        else if tables.isEmpty { layout = "no_tables" }
        else { layout = "unlabeled_or_other" }

        let audit: [String: Any] = [
            "axis": axis, "code": code, "doc_id": docID, "fy_end": fyEnd,
            "bucket": bucket, "reason": reason, "layout": layout,
            "n_tables": tables.count,
            "existing_answer": existing.answer,
            "existing_answer_unique": existing.unique,
            "neon_bucket": neonBucket ?? NSNull(),
            "neon_reason": neonReason ?? NSNull(),
            "table_sources": tableSources,
        ]
        return AxisExport(tables: tableJSON, cells: cellJSON, usable: usable, audit: audit)
    }

    static func cellRow(
        axis: String, code: String, docID: String, fyEnd: String,
        stored: [String: Any], storedUnit: String?,
        currentTables: [(Int, BreakdownTable)], extra: [String: Any]
    ) -> [[String: Any]] {
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
                    choices.append([
                        "id": "t\(tableIndex)_r\(r)_c\(c)",
                        "table_index": tableIndex,
                        "row_header": rowHeader,
                        "column_header": colHeaderParts.joined(separator: " / "),
                        "raw_text": cell,
                        "parsed_number": parsed,
                        "unit_hint": unitHint,
                    ])
                }
            }
        }
        var choiceList: [Any] = choices
        choiceList.append(noneOfThese)
        let storedAmount: Double? = {
            if let d = stored["amount"] as? Double { return d }
            if let n = stored["amount"] as? NSNumber { return n.doubleValue }
            return nil
        }()
        var matchedIDs: [String] = []
        if let amt = storedAmount {
            for c in choices {
                guard let n = c["parsed_number"] as? Double else { continue }
                let scales: [Double] = [1, 1_000, 1_000_000, 1_000_000_000]
                if scales.contains(where: { abs(n * $0 - amt) < 0.51 }) {
                    if let id = c["id"] as? String { matchedIDs.append(id) }
                }
            }
        }
        let cellAnswer: String
        let cellUnique: Bool
        if matchedIDs.count == 1 {
            cellAnswer = matchedIDs[0]
            cellUnique = true
        } else {
            cellAnswer = noneOfThese
            cellUnique = matchedIDs.isEmpty
        }
        var row: [String: Any] = [
            "axis": axis,
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
            "existing_answer": cellAnswer,
            "existing_answer_unique": cellUnique,
            "existing_answer_match_ids": matchedIDs,
        ]
        extra.forEach { row[$0.key] = $0.value }
        return [row]
    }

    static func extractNoteTables(noteType: String, xbrlDir: URL) -> [BreakdownTable] {
        let tags: [String]
        switch noteType {
        case "issued_shares_and_capital":
            tags = ["ChangesInNumberOfIssuedSharesStatedCapitalEtcTextBlock"]
        case "lease_liabilities":
            tags = [Xbrl.ifrsLeasesTextblockTag]
        case "borrowings_schedule":
            tags = [
                Xbrl.borrowingsScheduleTextblockTag,
                Xbrl.borrowingsScheduleNonConsolidatedTextblockTag,
                Xbrl.ifrsBondsAndBorrowingsTextblockTag,
                Xbrl.ifrsBorrowingsOnlyTextblockTag,
                Xbrl.ifrsBondsBorrowingsAndOtherFinancialLiabilitiesTextblockTag,
                "NotesToConsolidatedFinancialStatementsUSGAAPTextBlock",
            ]
        default:
            tags = []
        }
        for tag in tags {
            guard let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: tag),
                  html.lowercased().contains("<table")
            else { continue }
            let tables = BreakdownExtractor.allTablesFromHtml(html, defaultHeading: noteType)
            if !tables.isEmpty { return tables }
        }
        return []
    }
}

struct PocJevExportTests {
    @Test func committedJsonlHasNoneOfTheseWhenPresent() throws {
        let names = [
            "table_select_segment_info.jsonl", "table_select_geography.jsonl",
            "usable_segment_info.jsonl", "usable_geography.jsonl",
            "usable_revenue_recognition.jsonl", "table_select_notes.jsonl",
        ]
        for name in names {
            let url = PocJevIO.outDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
            for line in lines.prefix(15) {
                let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
                guard let dict = obj as? [String: Any], let choices = dict["choices"] as? [Any] else {
                    Issue.record("\(name) line missing choices")
                    continue
                }
                #expect(choices.last as? String == PocJevExport.noneOfThese)
            }
        }
    }

    @Test func exportCandidatesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BLT_POC_JEV_RUN"] == "1" else { return }
        try await PocJevExport.run()
        for name in ["table_select_segment_info.jsonl", "table_select_geography.jsonl",
                     "usable_segment_info.jsonl", "export_report.json"] {
            let url = PocJevIO.outDir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
