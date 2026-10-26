// 報告セグメント別ののれん（axis=`goodwill`）。行はセグメント / 調整 / 小計 / EntityTotal。
// セルは opening / closing / amortization / impairment。欠測は null。
// 分母は開示された合計（EntityTotal または BS のれん）。セグメントの和では埋めない。
// 差額埋めはしない。固定資産全体の減損表（ImpairmentLossEL）は使わない。
// 該当事項なしは 0。Jev は使わない。

import Foundation

struct GoodwillNoteFlags: Equatable {
    var unallocatedToReportableSegments: Bool
    var openingNoneDisclosed: Bool
    var amortizationNoneDisclosed: Bool
    var impairmentNoneDisclosed: Bool

    static let empty = GoodwillNoteFlags(
        unallocatedToReportableSegments: false, openingNoneDisclosed: false,
        amortizationNoneDisclosed: false, impairmentNoneDisclosed: false)

    /// 当期 TextBlock からフラグだけ読む。金額は生成しない。
    static func load(from xbrlDir: URL) -> GoodwillNoteFlags {
        let texts = GoodwillNoteText.load(from: xbrlDir)
        let unallocatedCurrent = texts.current(
            tag: Xbrl.goodwillUnallocatedToReportableSegmentsTextBlockTag)
        let goodwillNoteCurrent = texts.current(
            tag: Xbrl.goodwillAmortizationAndUnamortizedBalanceTextBlockTag)
        let goodwillNotePrior = texts.prior(
            tag: Xbrl.goodwillAmortizationAndUnamortizedBalanceTextBlockTag)
        let unallocatedPrior = texts.prior(
            tag: Xbrl.goodwillUnallocatedToReportableSegmentsTextBlockTag)
        let impairmentCurrent = texts.current(
            tag: Xbrl.segmentImpairmentLossOfNonCurrentAssetsOrGoodwillTextBlockTag)
        let segmentEtc = Xbrl.segmentInformationEtcTextBlockTags
            .compactMap { texts.current(tag: $0) }.joined(separator: "\n")
        let unallocatedText = unallocatedCurrent ?? ""
        let goodwillHeadingCurrent = GoodwillNoteText.headingPeriod(
            segmentEtc, heading: GoodwillNoteText.goodwillAmortizationHeading, current: true)
        let goodwillHeadingPrior = GoodwillNoteText.headingPeriod(
            segmentEtc, heading: GoodwillNoteText.goodwillAmortizationHeading, current: false)
        let impairmentHeadingCurrent = GoodwillNoteText.headingPeriod(
            segmentEtc, heading: GoodwillNoteText.segmentImpairmentHeading, current: true)
        return GoodwillNoteFlags(
            unallocatedToReportableSegments: GoodwillNoteText.isUnallocated(unallocatedText)
                || GoodwillNoteText.isUnallocated(segmentEtc)
                || unallocatedCurrent != nil,
            openingNoneDisclosed: GoodwillNoteText.isNoneDisclosed(goodwillNotePrior)
                || GoodwillNoteText.isNoneDisclosed(unallocatedPrior)
                || GoodwillNoteText.isNoneDisclosed(goodwillHeadingPrior),
            amortizationNoneDisclosed: GoodwillNoteText.isAmortizationNone(unallocatedText)
                || GoodwillNoteText.isAmortizationNone(goodwillNoteCurrent ?? "")
                || GoodwillNoteText.isAmortizationNone(goodwillHeadingCurrent ?? ""),
            impairmentNoneDisclosed: GoodwillNoteText.isNoneDisclosed(impairmentCurrent)
                || GoodwillNoteText.isNoneDisclosed(impairmentHeadingCurrent))
    }
}

enum GoodwillNormalizer {
    /// 公開軸 `goodwill` のスナップショット。4 セルがすべて空なら nil（not_found）。
    static func normalize(
        facts: [BreakdownFact], labelsByTag: [String: String] = [:],
        memberParents: [String: String] = [:],
        companyClosingTotal: (value: Double, tag: String)? = nil,
        notes: GoodwillNoteFlags = .empty
    ) -> BreakdownSnapshotPayload? {
        let closing = BreakdownNormalizer.normalizeGoodwill(
            facts: facts, total: companyClosingTotal?.value, totalTag: companyClosingTotal?.tag,
            axis: breakdownAxisGoodwill, labelsByTag: labelsByTag, memberParents: memberParents,
            period: .current, unallocatedToReportableSegments: notes.unallocatedToReportableSegments)
        let opening = BreakdownNormalizer.normalizeGoodwill(
            facts: facts, total: nil, totalTag: nil, axis: breakdownAxisGoodwill,
            labelsByTag: labelsByTag, memberParents: memberParents, period: .prior,
            unallocatedToReportableSegments: notes.unallocatedToReportableSegments)
        let amortization = BreakdownNormalizer.normalizeGoodwillAmortization(
            facts: facts, labelsByTag: labelsByTag, memberParents: memberParents)
        let impairment = BreakdownNormalizer.normalizeGoodwillImpairment(
            facts: facts, labelsByTag: labelsByTag, memberParents: memberParents)
        return assemble(
            opening: opening, closing: closing, amortization: amortization, impairment: impairment,
            notes: notes)
    }

    static func assemble(
        opening: BreakdownSnapshot?, closing: BreakdownSnapshot?,
        amortization: BreakdownSnapshot?, impairment: BreakdownSnapshot?,
        notes: GoodwillNoteFlags = .empty
    ) -> BreakdownSnapshotPayload? {
        guard opening != nil || closing != nil || amortization != nil || impairment != nil
            || notes.openingNoneDisclosed || notes.amortizationNoneDisclosed
            || notes.impairmentNoneDisclosed
        else { return nil }
        // 該当事項なしだけでは行が無い。期末または償却の行があるときだけ 0 を埋める。
        guard opening != nil || closing != nil || amortization != nil || impairment != nil else {
            return nil
        }

        var rows: [BreakdownRowPayload] = []
        var index: [String: Int] = [:]

        func append(from snapshot: BreakdownSnapshot?, cell: GoodwillCell) {
            guard let snapshot else { return }
            for source in snapshot.rows {
                if source.labelRaw == Xbrl.entityTotalMemberName { continue }
                let kind = remappedRowKind(source)
                if kind == breakdownRowKindEntityTotal { continue }
                if let existing = index[source.labelRaw], rows.indices.contains(existing) {
                    write(cell, amount: source.amount, into: &rows[existing])
                    continue
                }
                var row = BreakdownRowPayload(
                    labelRaw: source.labelRaw, label: source.label ?? source.labelRaw,
                    amount: 0, profit: nil, rowKind: kind)
                write(cell, amount: source.amount, into: &row)
                index[source.labelRaw] = rows.count
                rows.append(row)
            }
        }

        append(from: opening, cell: .opening)
        append(from: closing, cell: .closing)
        append(from: amortization, cell: .amortization)
        append(from: impairment, cell: .impairment)

        mergeDuplicateReconcilingRows(&rows)
        applyNoneDisclosedZeros(to: &rows, notes: notes)

        var warnings: [String] = []
        for snapshot in [opening, closing, amortization, impairment].compactMap({ $0 }) {
            for warning in snapshot.warnings where !warnings.contains(warning) {
                warnings.append(warning)
            }
        }
        let needsReview = [opening, closing, amortization, impairment]
            .compactMap { $0 }.contains { $0.needsReview }
        return BreakdownSnapshotPayload(
            axis: breakdownAxisGoodwill, denominator: 0, denominatorTag: "",
            rows: rows, sourceKind: breakdownSourceXbrlFacts, needsReview: needsReview,
            warnings: warnings,
            opening: metricTotals(opening, noneDisclosed: notes.openingNoneDisclosed),
            closing: metricTotals(closing, noneDisclosed: false),
            amortization: metricTotals(
                amortization, noneDisclosed: notes.amortizationNoneDisclosed),
            impairment: metricTotals(impairment, noneDisclosed: notes.impairmentNoneDisclosed))
    }

    private enum GoodwillCell {
        case opening, closing, amortization, impairment
    }

    private static func write(_ cell: GoodwillCell, amount: Double, into row: inout BreakdownRowPayload) {
        switch cell {
        case .opening: row.opening = amount
        case .closing: row.closing = amount
        case .amortization: row.amortization = amount
        case .impairment: row.impairment = amount
        }
    }

    private static func remappedRowKind(_ row: BreakdownRow) -> String {
        if row.labelRaw == Xbrl.entityTotalMemberName { return breakdownRowKindEntityTotal }
        return row.rowKind
    }

    private static func metricTotals(
        _ snapshot: BreakdownSnapshot?, noneDisclosed: Bool
    ) -> CapexMetricTotalsPayload? {
        if let snapshot, snapshot.denominator > 0 {
            return CapexMetricTotalsPayload(
                denominator: snapshot.denominator, denominatorTag: snapshot.denominatorTag)
        }
        if noneDisclosed {
            return CapexMetricTotalsPayload(denominator: 0, denominatorTag: goodwillCellStatusNoneDisclosed)
        }
        return nil
    }

    /// セグメント表の調整額と、のれん表の全社・消去が別 member に載るとき1行にまとめる。
    /// セルは period ごとに違う金額なので、同額判定はしない。
    private static func mergeDuplicateReconcilingRows(_ rows: inout [BreakdownRowPayload]) {
        let adjustment = "ReconcilingItemsMember"
        let unallocated = "UnallocatedAmountsAndEliminationMember"
        guard let adjustmentIndex = rows.firstIndex(where: {
            $0.labelRaw == adjustment && $0.rowKind == "reconciling"
        }),
            let unallocatedIndex = rows.firstIndex(where: {
                $0.labelRaw == unallocated && $0.rowKind == "reconciling"
            }),
            adjustmentIndex != unallocatedIndex
        else { return }
        func mergeCell(_ keep: Double?, _ other: Double?) -> Double? { keep ?? other }
        rows[unallocatedIndex].opening = mergeCell(
            rows[unallocatedIndex].opening, rows[adjustmentIndex].opening)
        rows[unallocatedIndex].closing = mergeCell(
            rows[unallocatedIndex].closing, rows[adjustmentIndex].closing)
        rows[unallocatedIndex].amortization = mergeCell(
            rows[unallocatedIndex].amortization, rows[adjustmentIndex].amortization)
        rows[unallocatedIndex].impairment = mergeCell(
            rows[unallocatedIndex].impairment, rows[adjustmentIndex].impairment)
        rows.remove(at: adjustmentIndex)
    }

    /// 該当事項なし / 償却額は発生しておりません。既存の抽出値は上書きしない。
    private static func applyNoneDisclosedZeros(
        to rows: inout [BreakdownRowPayload], notes: GoodwillNoteFlags
    ) {
        for index in rows.indices {
            if notes.openingNoneDisclosed, rows[index].opening == nil {
                rows[index].opening = 0
            }
            if notes.amortizationNoneDisclosed, rows[index].amortization == nil {
                rows[index].amortization = 0
            }
            if notes.impairmentNoneDisclosed, rows[index].impairment == nil {
                rows[index].impairment = 0
            }
        }
    }
}

enum GoodwillNoteText {
    struct Entry {
        var tag: String
        var contextRef: String
        var text: String
    }

    static func load(from xbrlDir: URL) -> [Entry] {
        let wanted = Set(
            [
                Xbrl.goodwillUnallocatedToReportableSegmentsTextBlockTag,
                Xbrl.goodwillAmortizationAndUnamortizedBalanceTextBlockTag,
                Xbrl.segmentImpairmentLossOfNonCurrentAssetsOrGoodwillTextBlockTag,
            ] + Xbrl.segmentInformationEtcTextBlockTags)
        var entries: [Entry] = []
        var dirs = [xbrlDir]
        dirs.append(contentsOf: overlayDirectories(in: xbrlDir))
        for dir in dirs {
            for file in XBRLUtils.findXbrlFiles(in: dir) {
                guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
                entries.append(contentsOf: parse(raw, wanted: wanted))
            }
        }
        return entries
    }

    static func parse(_ raw: String, wanted: Set<String>) -> [Entry] {
        var entries: [Entry] = []
        let ns = raw as NSString
        for tag in wanted.sorted() {
            let escaped = NSRegularExpression.escapedPattern(for: tag)
            let pattern = try! NSRegularExpression(
                pattern: "<(?:[A-Za-z_][\\w.-]*:)?" + escaped
                    + "\\b([^>]*)>([\\s\\S]*?)</(?:[A-Za-z_][\\w.-]*:)?" + escaped + ">",
                options: [])
            pattern.enumerateMatches(
                in: raw, options: [], range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                guard let match, match.numberOfRanges >= 3 else { return }
                let attrs = ns.substring(with: match.range(at: 1))
                let inner = ns.substring(with: match.range(at: 2))
                let context = attribute(attrs, name: "contextRef") ?? ""
                let text = BreakdownProseToolkit.plainText(from: inner.htmlEntityDecoded)
                entries.append(Entry(tag: tag, contextRef: context, text: text))
            }
        }
        return entries
    }

    static func isNoneDisclosed(_ text: String?) -> Bool {
        guard let text else { return false }
        let compact = compactText(text)
        if compact.contains("省略") { return false }
        if compact.contains("配分しておりません") { return false }
        return compact.contains("該当事項はありません")
            || compact.contains("該当事項なし")
            || compact.contains("記載すべき該当事項はありません")
    }

    static func isUnallocated(_ text: String) -> Bool {
        compactText(text).contains("報告セグメントに配分しておりません")
    }

    static func isAmortizationNone(_ text: String) -> Bool {
        compactText(text).contains("償却額は発生しておりません")
    }

    static let goodwillAmortizationHeading = "報告セグメントごとののれんの償却額及び未償却残高に関する情報"
    static let segmentImpairmentHeading = "報告セグメントごとの固定資産の減損損失に関する情報"

    /// セグメント情報等の親 TextBlock から、見出し配下の前/当連結会計年度本文を取る。
    static func headingPeriod(_ text: String, heading: String, current: Bool) -> String? {
        let compactHeading = compactText(heading)
        guard !compactHeading.isEmpty else { return nil }
        let compact = compactText(text)
        guard let headingRange = compact.range(of: compactHeading) else { return nil }
        var section = String(compact[headingRange.upperBound...])
        if let next = section.range(of: "【") {
            section = String(section[..<next.lowerBound])
        }
        let currentMarks = ["当連結会計年度", "当事業年度"]
        let priorMarks = ["前連結会計年度", "前事業年度"]
        let startMarks = current ? currentMarks : priorMarks
        let endMarks = current ? priorMarks : currentMarks
        var best: String?
        for mark in startMarks {
            guard let start = section.range(of: mark) else { continue }
            var body = String(section[start.upperBound...])
            for end in endMarks {
                if let range = body.range(of: end) {
                    body = String(body[..<range.lowerBound])
                }
            }
            if best == nil || body.count < best!.count { best = body }
        }
        return best ?? (section.isEmpty ? nil : section)
    }

    private static func compactText(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func attribute(_ attrs: String, name: String) -> String? {
        let pattern = try! NSRegularExpression(
            pattern: name + #"\s*=\s*"([^"]*)""#, options: [.caseInsensitive])
        let ns = attrs as NSString
        guard let match = pattern.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: ns.length)),
            match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

extension Array where Element == GoodwillNoteText.Entry {
    fileprivate func current(tag: String) -> String? {
        last {
            $0.tag == tag
                && ($0.contextRef.isEmpty
                    || BreakdownNormalizer.isCurrentPeriodContext($0.contextRef))
        }?.text
    }

    fileprivate func prior(tag: String) -> String? {
        last {
            $0.tag == tag && BreakdownNormalizer.isPriorPeriodContext($0.contextRef)
        }?.text
    }
}
