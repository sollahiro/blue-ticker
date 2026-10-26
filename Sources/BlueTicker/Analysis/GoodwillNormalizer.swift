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
        let unallocatedText = unallocatedCurrent ?? ""
        return GoodwillNoteFlags(
            unallocatedToReportableSegments: GoodwillNoteText.isUnallocated(unallocatedText)
                || unallocatedCurrent != nil,
            openingNoneDisclosed: GoodwillNoteText.isNoneDisclosed(goodwillNotePrior)
                || GoodwillNoteText.isNoneDisclosed(unallocatedPrior),
            amortizationNoneDisclosed: GoodwillNoteText.isAmortizationNone(unallocatedText)
                || GoodwillNoteText.isAmortizationNone(goodwillNoteCurrent ?? ""),
            impairmentNoneDisclosed: GoodwillNoteText.isNoneDisclosed(impairmentCurrent))
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
                let kind = remappedRowKind(source)
                if let existing = index[source.labelRaw], rows.indices.contains(existing) {
                    write(cell, amount: source.amount, into: &rows[existing])
                    if kind == breakdownRowKindEntityTotal {
                        rows[existing].rowKind = breakdownRowKindEntityTotal
                    }
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
            return CapexMetricTotalsPayload(denominator: 0, denominatorTag: "none_disclosed")
        }
        return nil
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
        let wanted: Set<String> = [
            Xbrl.goodwillUnallocatedToReportableSegmentsTextBlockTag,
            Xbrl.goodwillAmortizationAndUnamortizedBalanceTextBlockTag,
            Xbrl.segmentImpairmentLossOfNonCurrentAssetsOrGoodwillTextBlockTag,
        ]
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
