import Foundation

// Port of blue_ticker/utils/edinet_discovery.py

// withTaskGroup で [[String: Any]] を返すための @unchecked Sendable ラッパー。
// JSON 値は actor 内で生成され、所有権転送で受け渡す。
private struct YearDocs: @unchecked Sendable {
    let docs: [[String: Any]]
}

enum EdinetDiscovery {
    private static let seedDocTypes: Set<String> = [
        Api.docTypeAnnualReport,
        Api.docTypeQuarterlyReport,
        Api.docTypeHalfYearReport,
    ]
    private static let halfYearDocTypes: Set<String> = [
        Api.docTypeQuarterlyReport,
        Api.docTypeHalfYearReport,
    ]

    // MARK: - Main entry points

    /// 指定銘柄の過去 analysisYears 年分の有価証券報告書（+ 訂正書類）を返す。
    /// 各書類には edinet_fy_end / fiscal_year / period_type が付与される。
    static func buildDocumentIndexForCode(
        code: String,
        client: EdinetAPIClient,
        initialScanDays: Int = 365,
        analysisYears: Int = 5
    ) async -> [[String: Any]] {
        // ① 直近スキャンで有報または半期報告書を1件発見 → edinetCode を取得
        guard let recent = await findMostRecentFiling(code: code, client: client, scanDays: initialScanDays) else {
            return []
        }
        guard let edinetCode = recent["edinetCode"] as? String, !edinetCode.isEmpty else {
            return []
        }

        // ② 年次インデックスを並列取得
        let todayYear = utcCalendar.component(.year, from: Date())
        let scanStartYear = todayYear - analysisYears
        var allDocs: [[String: Any]] = []
        await withTaskGroup(of: YearDocs.self) { group in
            for year in scanStartYear...todayYear {
                group.addTask { YearDocs(docs: await client.ensureDocumentIndexForYear(year)) }
            }
            for await r in group {
                allDocs.append(contentsOf: r.docs)
            }
        }

        // ③ edinetCode でフィルタ（有報・訂正を分類）
        let annualDocs = allDocs.filter {
            $0["edinetCode"] as? String == edinetCode &&
            $0["docTypeCode"] as? String == Api.docTypeAnnualReport &&
            !($0["periodEnd"] as? String ?? "").isEmpty
        }
        let amendmentCandidates = allDocs.filter {
            $0["edinetCode"] as? String == edinetCode &&
            $0["docTypeCode"] as? String == Api.docTypeAmendment
        }

        // ④ periodEnd 降順ソート → 上位 analysisYears 件を選択し、メタ情報付与
        let sorted = annualDocs.sorted {
            ($0["periodEnd"] as? String ?? "") > ($1["periodEnd"] as? String ?? "")
        }
        var docs: [[String: Any]] = []
        for var doc in sorted.prefix(analysisYears) {
            guard let peDate = parseDateString(doc["periodEnd"] as? String) else { continue }
            let fyEndStr = formatDateISO(peDate)
            let fiscalYear = parseDateString(doc["periodStart"] as? String)
                .map { utcCalendar.component(.year, from: $0) }
                ?? (utcCalendar.component(.year, from: peDate) - 1)
            doc["edinet_fy_end"] = fyEndStr
            doc["fiscal_year"] = fiscalYear
            doc["period_type"] = "FY"
            docs.append(doc)
        }

        // ⑤ 訂正書類: parentDocID が選択済み有報に対応するものを付与
        let fyMetaByID: [String: (fyEnd: String, fiscalYear: Int?)] = Dictionary(
            uniqueKeysWithValues: docs.compactMap { doc -> (String, (String, Int?))? in
                guard let id = doc["docID"] as? String else { return nil }
                return (id, (doc["edinet_fy_end"] as? String ?? "", doc["fiscal_year"] as? Int))
            }
        )
        for var amendment in amendmentCandidates {
            guard let parentID = amendment["parentDocID"] as? String,
                  let meta = fyMetaByID[parentID] else { continue }
            amendment["edinet_fy_end"] = meta.fyEnd
            if let fy = meta.fiscalYear { amendment["fiscal_year"] = fy }
            amendment["period_type"] = "FY"
            amendment["_is_amendment"] = true
            docs.append(amendment)
        }
        return docs
    }

    /// 指定銘柄の半期/2Q報告書を返す。
    /// annualDocs を渡すと build_document_index_for_code の再呼び出しを省ける。
    static func buildHalfYearDocumentIndexForCode(
        code: String,
        client: EdinetAPIClient,
        initialScanDays: Int = 365,
        analysisYears: Int = 5,
        prebuiltAnnualDocs: [[String: Any]]? = nil
    ) async -> [[String: Any]] {
        let allDocs: [[String: Any]]
        if let prebuild = prebuiltAnnualDocs {
            allDocs = prebuild
        } else {
            allDocs = await buildDocumentIndexForCode(
                code: code, client: client,
                initialScanDays: initialScanDays, analysisYears: analysisYears
            )
        }
        let annualOnly = allDocs.filter {
            $0["docTypeCode"] as? String == Api.docTypeAnnualReport &&
            ($0["_is_amendment"] as? Bool) != true
        }
        guard !annualOnly.isEmpty else { return [] }

        // 年度ごとの (period_start, fy_end) を収集
        var fyPeriods: [String: (start: Date, end: Date)] = [:]
        for doc in annualOnly {
            guard let fyEndDate = parseDateString(doc["edinet_fy_end"] as? String),
                  let fyStartDate = parseDateString(doc["periodStart"] as? String) else { continue }
            fyPeriods[formatDateISO(fyEndDate)] = (fyStartDate, fyEndDate)
        }

        // 最新年度の翌年を追加（予測）
        if let newestFyEnd = fyPeriods.keys.max(),
           let (_, end) = fyPeriods[newestFyEnd] {
            let nextStart = addDays(end, 1)
            let nextEnd = addYearSafe(end, 1)
            fyPeriods[formatDateISO(nextEnd)] = (nextStart, nextEnd)
        }

        var docs: [[String: Any]] = []
        for fyEndStr in fyPeriods.keys.sorted(by: >) {
            if docs.count >= analysisYears { break }
            let (periodStart, fyEnd) = fyPeriods[fyEndStr]!
            if let found = await findHalfReportForFy(
                code: code, periodStart: periodStart, fyEnd: fyEnd, client: client
            ) {
                docs.append(found)
            }
        }
        return docs
    }

    // MARK: - Private helpers

    private static func findMostRecentFiling(
        code: String,
        client: EdinetAPIClient,
        scanDays: Int
    ) async -> [String: Any]? {
        let code4 = String(code.prefix(4))
        let today = utcStartOfDay(Date())
        let scanStart = addDays(today, -(scanDays - 1))

        let docsByDate = await client.getDocumentsForDateRange(start: scanStart, end: today)
        for dateStr in docsByDate.keys.sorted(by: >) {
            for doc in (docsByDate[dateStr] ?? []) ?? [] {
                let sec = (doc["secCode"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard sec.hasPrefix(code4) else { continue }
                guard let docType = doc["docTypeCode"] as? String, seedDocTypes.contains(docType) else { continue }
                guard let ec = doc["edinetCode"] as? String, !ec.isEmpty else { continue }
                return doc
            }
        }
        return nil
    }

    private static func findHalfReportForFy(
        code: String,
        periodStart: Date,
        fyEnd: Date,
        client: EdinetAPIClient
    ) async -> [String: Any]? {
        let code4 = String(code.prefix(4))
        let halfEnd = addDays(addMonthsSafe(periodStart, 6), -1)
        let fyEndStr = formatDateISO(fyEnd)
        let halfEndStr = formatDateISO(halfEnd)
        let periodStartStr = formatDateISO(periodStart)
        let today = utcStartOfDay(Date())
        let searchStart = addDays(halfEnd, 1)
        let searchEnd = min(addDays(halfEnd, 90), today)
        guard searchStart <= searchEnd else { return nil }

        let docsByDate = await client.getDocumentsForDateRange(start: searchStart, end: searchEnd)
        var candidates: [[String: Any]] = []
        for dateStr in docsByDate.keys.sorted(by: >) {
            for doc in (docsByDate[dateStr] ?? []) ?? [] {
                let sec = (doc["secCode"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard sec.hasPrefix(code4) else { continue }
                guard let docType = doc["docTypeCode"] as? String,
                      halfYearDocTypes.contains(docType) else { continue }
                let desc = doc["docDescription"] as? String ?? ""
                guard !desc.contains("訂正") && !desc.contains("補正") else { continue }

                let docPeriodEnd = doc["periodEnd"] as? String ?? ""
                let docPeriodStart = doc["periodStart"] as? String ?? ""
                if docType == Api.docTypeHalfYearReport {
                    // 半期報告書: periodEnd は通期期末、periodStart は期首
                    if !docPeriodEnd.isEmpty && !docPeriodEnd.hasPrefix(fyEndStr) { continue }
                    if !docPeriodStart.isEmpty && !docPeriodStart.hasPrefix(periodStartStr) { continue }
                } else {
                    // 旧2Q四半期報告書: periodEnd は2Q末
                    if !docPeriodEnd.isEmpty && !docPeriodEnd.hasPrefix(halfEndStr) { continue }
                    guard desc.contains("第2四半期") else { continue }
                }
                candidates.append(doc)
            }
        }
        guard let found = candidates.max(by: {
            ($0["submitDateTime"] as? String ?? "") < ($1["submitDateTime"] as? String ?? "")
        }) else { return nil }

        var result = found
        result["edinet_fy_end"] = fyEndStr
        result["fiscal_year"] = utcCalendar.component(.year, from: periodStart)
        result["period_type"] = "2Q"
        result["edinet_period_start"] = periodStartStr
        result["edinet_period_end"] = halfEndStr
        return result
    }

    // MARK: - Date helpers

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static func utcStartOfDay(_ date: Date) -> Date {
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return utcCalendar.date(from: comps)!
    }

    static func formatDateISO(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func addDays(_ date: Date, _ days: Int) -> Date {
        utcCalendar.date(byAdding: .day, value: days, to: date)!
    }

    private static func addMonthsSafe(_ date: Date, _ months: Int) -> Date {
        utcCalendar.date(byAdding: .month, value: months, to: date)!
    }

    private static func addYearSafe(_ date: Date, _ years: Int) -> Date {
        utcCalendar.date(byAdding: .year, value: years, to: date)!
    }
}
