// 本番 geography_llm 行を R2 GET + Jev 新経路で再計算して比較する。CI では走らない。
// `BLT_GEOGRAPHY_SCAN=1`、R2 XBRL 資格、`OPENROUTER_DECISION_API_KEY` が必要。
// R2 GET のみ。DB へは書かない。EDINET フォールバックもしない（apiKey=nil）。
// 訂正 130 overlay は掛けない（ingest の `resolveAnnualXbrlDirectory` とは非対称）。
// 7272 は原本 S100XRTH が 155,330、訂正 S100YTNF overlay 後が 137,712。

import Foundation
import Testing
@testable import BlueTickerCore

struct GeographyProdRow: Codable {
    var code: String
    var docID: String
    var needsReview: Bool
    var cacheVersion: String
    var sourceKind: String?
    var denominator: Double?
    var warnings: [String]
    var rows: [GeographyProdBreakdownRow]

    enum CodingKeys: String, CodingKey {
        case code
        case docID = "doc_id"
        case needsReview = "needs_review"
        case cacheVersion = "cache_version"
        case sourceKind = "source_kind"
        case denominator
        case warnings
        case rows
    }
}

struct GeographyProdBreakdownRow: Codable {
    var label: String?
    var amount: Double?
    var rowKind: String?

    enum CodingKeys: String, CodingKey {
        case label
        case amount
        case rowKind = "row_kind"
    }
}

@Suite struct GeographyJevLiveScanTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["BLT_GEOGRAPHY_SCAN"] == "1"
            && R2StorageConfig.resolveXbrlFromEnvironment() != nil
            && resolveOpenRouterDecisionsEndpoint() != nil
    }

    @Test(
        .enabled(if: enabled, "BLT_GEOGRAPHY_SCAN=1, R2 XBRL, OPENROUTER_DECISION_API_KEY required"),
        .timeLimit(.minutes(60))
    )
    func rescanGeographyLLMRowsWithJev() async throws {
        let env = ProcessInfo.processInfo.environment
        let listPath = env["BLT_GEOGRAPHY_SCAN_INPUT"]
            ?? "/opt/cursor/artifacts/geography-prod-rows.json"
        let outPath = env["BLT_GEOGRAPHY_SCAN_OUTPUT"]
            ?? "/opt/cursor/artifacts/geography-jev-scan.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: listPath))
        let decoded = try JSONDecoder().decode([GeographyProdRow].self, from: data)
        let codesRaw = env["BLT_GEOGRAPHY_SCAN_CODES"] ?? ""
        let wantedCodes = Set(
            codesRaw.split { $0 == "," || $0 == " " || $0 == "\n" }
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        let rows = wantedCodes.isEmpty
            ? decoded
            : decoded.filter { wantedCodes.contains($0.code) }
        let config = try #require(R2StorageConfig.resolveXbrlFromEnvironment())
        let endpoint = try #require(resolveOpenRouterDecisionsEndpoint())
        let cacheOverride = env["BLT_GEOGRAPHY_SCAN_CACHE"]
        let workDir: URL
        if let cacheOverride, !cacheOverride.isEmpty {
            workDir = URL(fileURLWithPath: cacheOverride, isDirectory: true)
        } else {
            workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("blt-geo-scan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        }
        let store = EdinetCacheStore(cacheDir: workDir, maxXbrlBytes: nil)
        let client = EdinetAPIClient(
            apiKey: nil, cacheStore: store, xbrlObjectStore: R2XbrlObjectStore(config: config))
        let useFake = env["BLT_GEOGRAPHY_SCAN_FAKE"] == "1"
        let columnDecider: any RevenueRecognitionColumnDeciding
        if useFake {
            columnDecider = FakeRevenueRecognitionColumnDecider()
        } else {
            columnDecider = OpenRouterGeographyColumnDecider(
                client: OpenRouterDecisionsClient(endpoint: endpoint))
        }

        var xbrlDirs: [String: URL] = [:]
        var missingXbrl: [String] = []
        var seen = Set<String>()
        for row in rows {
            if seen.contains(row.docID) { continue }
            seen.insert(row.docID)
            if store.hasXbrlDir(row.docID, saveDir: workDir) {
                xbrlDirs[row.docID] = store.xbrlDir(row.docID, saveDir: workDir)
                continue
            }
            if let dir = await client.downloadDocument(row.docID, saveDir: workDir),
               store.hasXbrlDir(row.docID, saveDir: workDir)
            {
                xbrlDirs[row.docID] = dir
            } else {
                missingXbrl.append(row.docID)
            }
        }

        var same: [[String: Any]] = []
        var changed: [[String: Any]] = []
        var nowNeedsReview: [[String: Any]] = []
        var jevWorse: [[String: Any]] = []
        var jevBetter: [[String: Any]] = []
        var equivalentish: [[String: Any]] = []
        var errors: [[String: Any]] = []

        for row in rows {
            guard let xbrlDir = xbrlDirs[row.docID] else {
                errors.append(["code": row.code, "doc_id": row.docID, "why": "xbrl_missing"])
                continue
            }
            let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)
            let sales = BreakdownFinancialsResolver.financialsCanonicalSales(xbrlDir: xbrlDir)
            let (snapshot, source, audit) = await GeographyBreakdownResolver.resolve(
                geography: geography, consolidatedSales: sales,
                columnDecider: columnDecider,
                labelsByTag: XBRLUtils.loadLabelsByTag(in: xbrlDir),
                fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir),
                docID: row.docID)

            var comparison = compare(prod: row, snapshot: snapshot, source: source, audit: audit)
            comparison.record["extract_method"] = geography.method
            comparison.record["table_count"] = geography.tables.count
            comparison.record["headings"] = geography.tables.map { $0.heading }
            comparison.record["table_periods"] = geography.tables.map { $0.period ?? "" }
            if let sales { comparison.record["consolidated_sales"] = sales }
            if let notes = audit?.notes { comparison.record["audit_notes"] = notes }
            if let selected = audit?.periodColumn { comparison.record["jev_column"] = selected }
            if let review = audit?.jev?.calls.last(where: {
                $0.question == OpenRouterSegmentNoteDecider.reviewDecisionQuestion
            }) {
                comparison.record["review_selected"] = review.selected ?? ""
                if let probability = review.probability {
                    comparison.record["review_probability"] = probability
                }
                comparison.record["review_applied"] = review.applied
                if review.applied, review.selected == GeographyBreakdownLLMNormalizer.reviewWrong {
                    comparison.record["review_action"] = "demote"
                } else if review.applied, review.selected == GeographyBreakdownLLMNormalizer.reviewCorrect {
                    comparison.record["review_action"] = "recover"
                } else {
                    comparison.record["review_action"] = "keep"
                }
            }
            if let source = audit?.jev?.decisionSource {
                comparison.record["decision_source"] = source
            }
            comparison.record["quality"] = qualityClass(prod: row, snapshot: snapshot, record: comparison.record)
            if !store.hasXbrlDir(row.docID, saveDir: workDir) {
                comparison.record["xbrl_status"] = "missing_on_disk"
            } else if geography.method == "not_found" && geography.tables.isEmpty {
                comparison.record["xbrl_status"] = "extract_empty"
            } else {
                comparison.record["xbrl_status"] = "ok"
            }
            switch comparison.record["quality"] as? String {
            case "jev_worse": jevWorse.append(comparison.record)
            case "jev_better": jevBetter.append(comparison.record)
            case "equivalent": equivalentish.append(comparison.record)
            default: break
            }
            switch comparison.bucket {
            case "same":
                same.append(comparison.record)
            case "now_needs_review":
                nowNeedsReview.append(comparison.record)
                changed.append(comparison.record)
            case "error":
                errors.append(comparison.record)
            default:
                changed.append(comparison.record)
            }
        }

        var whyCounts: [String: Int] = [:]
        for item in changed {
            let why = (item["why"] as? String).flatMap {
                $0.split(separator: " | ").first.map(String.init)
            } ?? ""
            whyCounts[why, default: 0] += 1
        }
        let newlyClean = (same + changed).filter {
            ($0["prod_needs_review"] as? Bool) == true
                && ($0["new_needs_review"] as? Bool) == false
        }
        let demoted = (same + changed + nowNeedsReview).filter {
            ($0["review_action"] as? String) == "demote"
        }
        let recovered = (same + changed).filter {
            ($0["review_action"] as? String) == "recover"
        }
        let uniqueDemoted = Dictionary(grouping: demoted, by: { $0["code"] as? String ?? "" })
            .values.compactMap(\.first)
        let uniqueRecovered = Dictionary(grouping: recovered, by: { $0["code"] as? String ?? "" })
            .values.compactMap(\.first)
        let artifact: [String: Any] = [
            "prod_row_count": rows.count,
            "companies": Set(rows.map(\.code)).count,
            "same": same.count,
            "changed": changed.count,
            "now_needs_review": nowNeedsReview.count,
            "jev_worse": jevWorse.count,
            "jev_better": jevBetter.count,
            "equivalent": equivalentish.count + same.count,
            "errors": errors.count,
            "missing_xbrl": missingXbrl,
            "missing_xbrl_count": missingXbrl.count,
            "newly_clean_count": newlyClean.count,
            "newly_clean": newlyClean,
            "demoted_count": uniqueDemoted.count,
            "demoted": uniqueDemoted,
            "recovered_count": uniqueRecovered.count,
            "recovered": uniqueRecovered,
            "why_counts": whyCounts,
            "sample_changed": Array(changed.prefix(25)),
            "changed_records": changed,
            "now_needs_review_records": nowNeedsReview,
            "jev_worse_records": jevWorse,
            "jev_better_records": jevBetter,
            "changed_codes": Array(Set(changed.compactMap { $0["code"] as? String })).sorted(),
            "error_codes": errors.compactMap { $0["code"] as? String }.sorted(),
        ]
        let outData = try JSONSerialization.data(
            withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try outData.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data(
            """
            geography Jev scan same=\(same.count) changed=\(changed.count) \
            now_needs_review=\(nowNeedsReview.count) jev_worse=\(jevWorse.count) \
            jev_better=\(jevBetter.count) demoted=\(uniqueDemoted.count) \
            recovered=\(uniqueRecovered.count) errors=\(errors.count)
            """.utf8))
        #expect(errors.count < rows.count || rows.isEmpty)
        if !useFake {
            #expect(jevWorse.isEmpty)
        }
    }

    private func qualityClass(
        prod: GeographyProdRow, snapshot: BreakdownSnapshot?, record: [String: Any]
    ) -> String {
        let prodPublic = isPubliclyServableBreakdown(
            source: breakdownSourceGeographyLLM,
            needsReview: prod.needsReview,
            warnings: prod.warnings)
        let newPublic: Bool = {
            guard let snapshot else { return false }
            return isPubliclyServableBreakdown(
                source: breakdownSourceGeographyLLM,
                needsReview: snapshot.needsReview,
                warnings: snapshot.warnings)
        }()
        let why = record["why"] as? String ?? ""
        if why.isEmpty { return "equivalent" }
        let labelsOnlyOfWhich = why.contains("labels") && (
            why.contains("うち") || why.contains("米国") || why.contains("オーストラリア"))
        if prodPublic && !newPublic {
            let warnings = snapshot?.warnings ?? []
            if warnings.contains(GeographyBreakdownLLMNormalizer.subtotalMismatchWarning)
                || warnings.contains("llm_row_sum_mismatch")
                || warnings.contains("geography_label_mismatch")
                || warnings.contains(RevenueRecognitionColumnNormalizer.warningLowConfidence)
                || warnings.contains(RevenueRecognitionColumnNormalizer.warningNoneOfTheseOverridden)
                || warnings.contains(GeographyBreakdownLLMNormalizer.warningFinalReviewWrong)
                || warnings.contains(GeographyBreakdownLLMNormalizer.warningColumnSampleDisagreement)
                || warnings.contains(GeographyBreakdownLLMNormalizer.warningColumnSampleInsufficient)
                || warnings.contains(GeographyBreakdownLLMNormalizer.warningCoverageBelowSales)
            {
                return "fail_closed"
            }
            let periods = record["table_periods"] as? [String] ?? []
            if snapshot == nil, !periods.isEmpty, periods.allSatisfy({ $0 == "前期" }) {
                return "fail_closed"
            }
            return "jev_worse"
        }
        let lunaOverflow = prod.rows.contains { ($0.amount ?? 0) > 1e15 }
        if !prodPublic && newPublic { return "jev_better" }
        if prodPublic && newPublic && lunaOverflow { return "jev_better" }
        if labelsOnlyOfWhich { return "jev_better" }
        if prodPublic && newPublic, recoveredMissingRegions(prod: prod, snapshot: snapshot) {
            return "jev_better"
        }
        if let snapshot, prodPublic && newPublic,
           amountsMatchIgnoringLabels(prod: prod, snapshot: snapshot)
        {
            return "equivalent"
        }
        if why.contains("amounts") {
            // Luna の桁コピー・年度取り違え。ラベル集合が同じなら Jev の表内金額を正とする。
            if prodPublic && newPublic {
                let prodLabels = Set(
                    prod.rows.filter { $0.rowKind == "segment" }.compactMap(\.label))
                let newLabels = Set(
                    snapshot?.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw) ?? [])
                if prodLabels == newLabels { return "jev_better" }
                return "jev_worse"
            }
            return "changed"
        }
        return "equivalent"
    }

    private func recoveredMissingRegions(
        prod: GeographyProdRow, snapshot: BreakdownSnapshot?
    ) -> Bool {
        guard let snapshot else { return false }
        let prodSum = prod.rows.filter { $0.rowKind == "segment" }.compactMap(\.amount).reduce(0, +)
        let newSum = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.amount).reduce(0, +)
        let denom = snapshot.denominator
        guard denom != 0 else { return false }
        let prodDenom = prod.denominator ?? denom
        guard prodDenom != 0 else { return false }
        let prodCoverage = prodSum / prodDenom
        let newCoverage = newSum / denom
        return newCoverage > prodCoverage + 0.01 && newCoverage <= 1.05
    }

    private func amountsMatchIgnoringLabels(
        prod: GeographyProdRow, snapshot: BreakdownSnapshot
    ) -> Bool {
        let prodVals = prod.rows.filter { $0.rowKind == "segment" }.compactMap(\.amount).sorted()
        let newVals = snapshot.rows.filter { $0.rowKind == "segment" }.map(\.amount).sorted()
        guard prodVals.count == newVals.count, prodVals.count >= 1 else { return false }
        return zip(prodVals, newVals).allSatisfy { old, new in
            abs(old - new) <= max(1.0, abs(old) * 1e-6)
        }
    }

    private func compare(
        prod: GeographyProdRow,
        snapshot: BreakdownSnapshot?,
        source: GeographyBreakdownSource,
        audit: LLMBreakdownAudit?
    ) -> (bucket: String, record: [String: Any]) {
        let prodLabels = prod.rows.filter { $0.rowKind == "segment" }.compactMap(\.label).sorted()
        let prodAmounts = Dictionary(
            prod.rows.filter { $0.rowKind == "segment" }.compactMap { row -> (String, Double)? in
                guard let label = row.label, let amount = row.amount else { return nil }
                return (label, amount)
            },
            uniquingKeysWith: { first, _ in first })

        guard let snapshot else {
            let why: String
            if let reason = audit?.notApplicableReason {
                why = "nil_snapshot not_applicable=\(reason)"
            } else {
                why = "nil_snapshot source=\(source.rawValue)"
            }
            return (
                "changed",
                [
                    "code": prod.code, "doc_id": prod.docID, "why": why,
                    "source": source.rawValue,
                    "prod_needs_review": prod.needsReview,
                    "prod_labels": prodLabels,
                ])
        }

        let newLabels = snapshot.rows.filter { $0.rowKind == "segment" }.map {
            BreakdownRowPayload.displayLabel(categoryGroup: $0.categoryGroup ?? $0.labelRaw, category: $0.category)
        }.sorted()
        var amountMismatches: [String] = []
        for label in Set(prodLabels).union(newLabels) {
            let old = prodAmounts[label]
            let new = snapshot.rows.first {
                $0.rowKind == "segment"
                    && BreakdownRowPayload.displayLabel(
                        categoryGroup: $0.categoryGroup ?? $0.labelRaw, category: $0.category) == label
            }?.amount
            if let old, let new {
                if abs(old - new) > max(1.0, abs(old) * 1e-6) {
                    amountMismatches.append("\(label) prod=\(old) new=\(new)")
                }
            } else if old != nil || new != nil {
                amountMismatches.append("\(label) prod=\(old as Any) new=\(new as Any)")
            }
        }

        var reasons: [String] = []
        if source != .geographyLLM {
            reasons.append("source=\(source.rawValue)")
        }
        if prodLabels != newLabels {
            reasons.append(
                "labels prod=\(prodLabels.joined(separator: "/")) new=\(newLabels.joined(separator: "/"))")
        }
        if !amountMismatches.isEmpty {
            reasons.append("amounts \(amountMismatches.prefix(4).joined(separator: "; "))")
        }
        if snapshot.needsReview != prod.needsReview {
            reasons.append("needs_review prod=\(prod.needsReview) new=\(snapshot.needsReview)")
        }

        var record: [String: Any] = [
            "code": prod.code,
            "doc_id": prod.docID,
            "source": source.rawValue,
            "prod_needs_review": prod.needsReview,
            "new_needs_review": snapshot.needsReview,
            "prod_labels": prodLabels,
            "new_labels": newLabels,
            "warnings": snapshot.warnings,
            "why": reasons.joined(separator: " | "),
        ]
        if let denom = prod.denominator {
            record["prod_denominator"] = denom
        }
        record["new_denominator"] = snapshot.denominator
        if reasons.isEmpty {
            return ("same", record)
        }
        let bucket = (!prod.needsReview && snapshot.needsReview) ? "now_needs_review" : "changed"
        return (bucket, record)
    }
}
