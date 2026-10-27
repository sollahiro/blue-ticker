// 報告セグメント軸（`segment`）。出典はセグメント情報の報告セグメント表と
// XBRL ReportableSegment facts だけ。製品表・地域別関連情報からは作らない。

import Foundation

enum SegmentBreakdownSource: String {
    case xbrlFacts = "xbrl_facts"
    case stackedSegmentPnL = "stacked_segment_pnl"
    case segmentInfoLLM = "segment_info_llm"
    case sameAs = "same_as"
    case notFound = "not_found"
}

enum SegmentBreakdownResolver {

    static func resolve(
        reportable: ExtractedBreakdown,
        consolidatedSales: Double?,
        labelsByTag: [String: String] = [:],
        denominatorTag: String? = nil,
        segmentInfoDecider: (any SegmentInfoDeciding)? = nil,
        columnDecider: (any RevenueRecognitionColumnDeciding)? = nil,
        segmentProfitDecider: (any SegmentProfitDeciding)? = nil,
        fiscalYearEnd: String? = nil,
        docID: String = "",
        xbrlDir: URL? = nil,
        pattern: SegmentNotePatternOutcome? = nil,
        employeeLabels: Set<String> = []
    ) async -> (snapshot: BreakdownSnapshot?, source: SegmentBreakdownSource, audit: LLMBreakdownAudit?) {
        let factsInput = ExtractedBreakdown(
            method: "xbrl_facts", tables: reportable.tables, facts: reportable.facts,
            rowLabelsByTag: reportable.rowLabelsByTag)
        var factsSnapshot = BreakdownNormalizer.normalize(
            factsInput, consolidatedSales: consolidatedSales, labelsByTag: labelsByTag,
            reportableSegmentAxis: true)
        if let snapshot = factsSnapshot {
            factsSnapshot = BreakdownNormalizer.publishingAsSegment(snapshot)
        }
        var profitAudit: LLMBreakdownAudit?

        // 決定論で利益タグが決まらず profit が全行 null のとき、セグメント値のある既存タグから
        // 会社のセグメント利益の行を Jev に選ばせる（9201 日本航空の財務・法人所得税前利益）。
        if let snapshot = factsSnapshot, let segmentProfitDecider,
           !snapshot.needsReview,
           !snapshot.rows.contains(where: { $0.profit != nil }),
           !BreakdownNormalizer.isFinancialBasisDenominatorTag(snapshot.denominatorTag)
        {
            let candidates = SegmentProfitJevPicker.candidates(
                facts: reportable.facts, rowLabelsByTag: reportable.rowLabelsByTag,
                memberLabels: labelsByTag, amountTag: snapshot.denominatorTag)
            let picked = await SegmentProfitJevPicker.pick(
                candidates: candidates, facts: reportable.facts,
                salesLabel: reportable.rowLabelsByTag[snapshot.denominatorTag]?.sorted().first
                    ?? snapshot.denominatorTag,
                decider: segmentProfitDecider, docID: docID)
            if !candidates.isEmpty {
                profitAudit = LLMBreakdownAudit(
                    sourceTableIndex: nil, periodColumn: nil, unit: "",
                    profitDisclosed: picked.tag != nil, notes: "segment_profit_jev",
                    jev: picked.audit)
            }
            if let tag = picked.tag,
               let withProfit = BreakdownNormalizer.normalize(
                   factsInput, consolidatedSales: consolidatedSales, labelsByTag: labelsByTag,
                   profitTagOverride: tag, reportableSegmentAxis: true)
            {
                factsSnapshot = BreakdownNormalizer.publishingAsSegment(withProfit)
            }
        }

        if let snapshot = factsSnapshot, !snapshot.needsReview,
           snapshot.rows.contains(where: { $0.rowKind == "segment" })
        {
            return (
                applyingPatternAndJoin(snapshot, pattern: pattern, employeeLabels: employeeLabels),
                .xbrlFacts, profitAudit)
        }

        if let stacked = StackedSegmentPnLNormalizer.normalize(
            reportable, consolidatedSales: consolidatedSales, salesDenominatorTag: denominatorTag)
        {
            var published = BreakdownNormalizer.publishingAsSegment(stacked)
            published.sourceKind = breakdownSourceStackedSegmentPnL
            return (
                applyingPatternAndJoin(published, pattern: pattern, employeeLabels: employeeLabels),
                .stackedSegmentPnL, nil)
        }

        let reportableTables = reportable.tables.filter { table in
            table.heading != BreakdownExtractor.productOrServiceHeading
                && table.heading != BreakdownExtractor.revenueRecognitionHeading
        }
        if !reportableTables.isEmpty {
            let scoped = ExtractedBreakdown(
                method: reportable.method, tables: reportableTables, facts: reportable.facts,
                rowLabelsByTag: reportable.rowLabelsByTag)
            if let infoDecider = segmentInfoDecider
                ?? columnDecider.map({ SegmentInfoDeciderFromColumnDecider(columnDecider: $0) })
            {
                let (snapshot, audit) = await SegmentInfoLLMNormalizer.normalize(
                    scoped, consolidatedSales: consolidatedSales, decider: infoDecider,
                    fiscalYearEnd: fiscalYearEnd, docID: docID,
                    salesDenominatorTag: denominatorTag,
                    publishedAxis: breakdownAxisSegment)
                if let snapshot, BusinessBreakdownResolver.hasUsableSegmentRows(snapshot) {
                    let published = BreakdownNormalizer.publishingAsSegment(snapshot)
                    return (
                        applyingPatternAndJoin(
                            published, pattern: pattern, employeeLabels: employeeLabels),
                        .segmentInfoLLM, audit)
                }
            }
        }

        if let oneRow = oneRowSnapshot(
            reportable: reportable, consolidatedSales: consolidatedSales,
            labelsByTag: labelsByTag, pattern: pattern, xbrlDir: xbrlDir)
        {
            return (
                applyingPatternAndJoin(oneRow, pattern: pattern, employeeLabels: employeeLabels),
                .xbrlFacts, nil)
        }

        if let factsSnapshot, factsSnapshot.rows.contains(where: { $0.rowKind == "segment" }) {
            return (
                applyingPatternAndJoin(
                    factsSnapshot, pattern: pattern, employeeLabels: employeeLabels),
                .xbrlFacts, nil)
        }

        return (nil, .notFound, nil)
    }

    static func sameAsSnapshot(axis: String) -> BreakdownSnapshot {
        BreakdownSnapshot(
            axis: axis, denominator: 0, denominatorTag: "", rows: [],
            sourceKind: breakdownSourceSameAs, needsReview: false, warnings: [],
            sameAs: breakdownAxisSegment)
    }

    static func oneRowSnapshot(
        reportable: ExtractedBreakdown,
        consolidatedSales: Double?,
        labelsByTag: [String: String],
        pattern: SegmentNotePatternOutcome?,
        xbrlDir: URL? = nil
    ) -> BreakdownSnapshot? {
        let classification = pattern?.classification
        let allowOneRow = classification == .singleSegment
            || classification == .omittedDominant90pct
        guard allowOneRow else { return nil }
        guard let amount = consolidatedSales, amount != 0 else { return nil }

        let members = currentSegmentMembers(in: reportable.facts)
        let member: String?
        let label: String
        if members.count == 1, let only = members.first {
            member = only
            label = labelsByTag[only] ?? only
        } else if classification == .omittedDominant90pct,
                  let named = pattern?.evidenceSentence.flatMap({
                      SegmentNotePatternClassifier.dominantBusinessName(fromEvidence: $0)
                  })
        {
            member = nil
            label = named
        } else if classification == .singleSegment,
                  let dir = xbrlDir,
                  let tagged = XBRLUtils.soleReportableSegmentChild(
                      in: dir, labelsByTag: labelsByTag)
        {
            member = tagged.member
            label = tagged.label
        } else if classification == .singleSegment,
                  let named = pattern?.evidenceSentence.flatMap({
                      SegmentNotePatternClassifier.lastBusinessName(in: $0)
                  })
        {
            member = nil
            label = named
        } else {
            return nil
        }

        let disclosure = classification == .omittedDominant90pct
            ? breakdownDisclosureBasisDominant90pct : nil
        let basis = BreakdownNormalizer.segmentBasis(
            forMembers: members.isEmpty ? [label] : members)
        let row = BreakdownRow(
            labelRaw: member ?? label,
            label: label,
            amount: amount,
            share: 1,
            profit: nil,
            rowKind: "segment",
            segmentBasis: basis,
            disclosureBasis: disclosure)
        return BreakdownSnapshot(
            axis: breakdownAxisSegment,
            denominator: amount,
            denominatorTag: "income_statement.sales",
            rows: [row],
            sourceKind: breakdownSourceXbrlFacts,
            needsReview: false,
            warnings: [],
            disclosureBasis: disclosure)
    }

    static func applyingPatternAndJoin(
        _ snapshot: BreakdownSnapshot,
        pattern: SegmentNotePatternOutcome?,
        employeeLabels: Set<String>
    ) -> BreakdownSnapshot {
        var copy = snapshot
        copy.axis = breakdownAxisSegment
        if pattern?.needsReview == true {
            copy.needsReview = true
        }
        if copy.disclosureBasis == nil, pattern?.classification == .omittedDominant90pct {
            copy.disclosureBasis = breakdownDisclosureBasisDominant90pct
            copy.rows = copy.rows.map { row in
                var row = row
                if row.rowKind == "segment" {
                    row.disclosureBasis = breakdownDisclosureBasisDominant90pct
                }
                return row
            }
        }
        let segmentLabels = Set(
            copy.rows.filter { $0.rowKind == "segment" }.compactMap { $0.label ?? $0.labelRaw }
        )
        if SegmentNotePatternClassifier.employeesJoinUnavailable(
            segmentLabels: segmentLabels, employeeLabels: employeeLabels)
        {
            copy.employeesJoin = breakdownEmployeesJoinUnavailable
            if !copy.warnings.contains(breakdownWarningEmployeesJoinUnavailable) {
                copy.warnings.append(breakdownWarningEmployeesJoinUnavailable)
            }
        }
        return copy
    }

    static func currentSegmentMembers(in facts: [BreakdownFact]) -> [String] {
        var members: [String] = []
        var seen = Set<String>()
        for fact in facts {
            guard BreakdownNormalizer.isCurrentPeriodContext(fact.contextRef) else { continue }
            guard let member = XBRLUtils.primaryBreakdownMember(fact.dimensions) else { continue }
            guard !Xbrl.segmentSubtotalMemberNames.contains(member),
                !BreakdownMemberRoles.isReconciling(member),
                !Xbrl.segmentOtherBusinessMemberNames.contains(member)
            else { continue }
            if seen.insert(member).inserted { members.append(member) }
        }
        return members
    }
}

enum ProductServiceBreakdownResolver {

    /// 製品・サービス軸。報告セグメント facts は使わない。
    static func resolve(
        product: ExtractedBreakdown,
        consolidatedSales: Double?,
        labelsByTag: [String: String] = [:],
        denominatorTag: String? = nil,
        columnDecider: (any RevenueRecognitionColumnDeciding)? = nil,
        segmentInfoDecider: (any SegmentInfoDeciding)? = nil,
        rowRoleDecider: (any RevenueRecognitionRowRoleDeciding)? = nil,
        fiscalYearEnd: String? = nil,
        docID: String = ""
    ) async -> (snapshot: BreakdownSnapshot?, source: BusinessBreakdownSource, audit: LLMBreakdownAudit?) {
        _ = labelsByTag
        if product.tables.isEmpty {
            return (nil, .notFound, nil)
        }
        if product.tables.contains(where: {
            $0.heading == BreakdownExtractor.revenueRecognitionHeading
                || $0.heading.contains("収益の分解")
        }) {
            if let columnDecider {
                let (snapshot, audit) = await RevenueRecognitionColumnNormalizer.normalize(
                    product, consolidatedSales: consolidatedSales, decider: columnDecider,
                    fiscalYearEnd: fiscalYearEnd, docID: docID, denominatorTag: denominatorTag,
                    rowRoleDecider: rowRoleDecider)
                if let snapshot, BusinessBreakdownResolver.hasUsableSegmentRows(snapshot) {
                    return (snapshot, .revenueRecognitionLLM, audit)
                }
                return (nil, .notFound, audit)
            }
            return (nil, .notFound, nil)
        }
        if let infoDecider = segmentInfoDecider
            ?? columnDecider.map({ SegmentInfoDeciderFromColumnDecider(columnDecider: $0) })
        {
            let (snapshot, audit) = await SegmentInfoLLMNormalizer.normalize(
                product, consolidatedSales: consolidatedSales, decider: infoDecider,
                fiscalYearEnd: fiscalYearEnd, docID: docID,
                salesDenominatorTag: denominatorTag)
            if audit?.notApplicableReason
                == BusinessBreakdownNotApplicableReason.geographyOnly.rawValue
            {
                return (nil, .notFound, audit)
            }
            if let snapshot, BusinessBreakdownResolver.hasUsableSegmentRows(snapshot) {
                return (snapshot, .segmentInfoLLM, audit)
            }
            return (nil, .notFound, audit)
        }
        return (nil, .notFound, nil)
    }
}
