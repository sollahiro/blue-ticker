// 本番 segment_info_llm 行を R2 GET + Jev 新経路で再計算して比較する。CI では走らない。
// `BLT_SEGMENT_INFO_SCAN=1`、R2 XBRL 資格、`OPENROUTER_DECISION_API_KEY` が必要。
// R2 GET のみ。DB へは書かない。EDINET フォールバックもしない（apiKey=nil）。

import Foundation
import Testing
@testable import BlueTickerCore

struct SegmentInfoProdRow: Codable {
    var code: String
    var docID: String
    var needsReview: Bool
    var cacheVersion: String
    var sourceKind: String?
    var denominator: Double?
    var warnings: [String]
    var rows: [SegmentInfoProdBreakdownRow]

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

struct SegmentInfoProdBreakdownRow: Codable {
    var label: String?
    var amount: Double?
    var profit: Double?
    var rowKind: String?

    enum CodingKeys: String, CodingKey {
        case label
        case amount
        case profit
        case rowKind = "row_kind"
    }
}

@Suite struct SegmentInfoJevLiveScanTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["BLT_SEGMENT_INFO_SCAN"] == "1"
            && R2StorageConfig.resolveXbrlFromEnvironment() != nil
            && resolveOpenRouterDecisionsEndpoint() != nil
    }

    @Test(
        .enabled(if: enabled, "BLT_SEGMENT_INFO_SCAN=1, R2 XBRL, OPENROUTER_DECISION_API_KEY required"),
        .timeLimit(.minutes(60))
    )
    func rescanSegmentInfoLLMRowsWithJev() async throws {
        let env = ProcessInfo.processInfo.environment
        let listPath = env["BLT_SEGMENT_INFO_SCAN_INPUT"]
            ?? "/opt/cursor/artifacts/segment-info-prod-rows.json"
        let outPath = env["BLT_SEGMENT_INFO_SCAN_OUTPUT"]
            ?? "/opt/cursor/artifacts/segment-info-jev-scan.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: listPath))
        let rows = try JSONDecoder().decode([SegmentInfoProdRow].self, from: data)
        let config = try #require(R2StorageConfig.resolveXbrlFromEnvironment())
        let endpoint = try #require(resolveOpenRouterDecisionsEndpoint())
        let cacheOverride = env["BLT_SEGMENT_INFO_SCAN_CACHE"]
        let workDir: URL
        if let cacheOverride, !cacheOverride.isEmpty {
            workDir = URL(fileURLWithPath: cacheOverride, isDirectory: true)
        } else {
            workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("blt-seginfo-scan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        }
        // Default XBRL cache cap is 2 GB. A 278-doc scan exceeds it, so later
        // downloads evict earlier trees and extractSegmentInfo sees an empty
        // directory (counted as not_found). The scan must not evict.
        let store = EdinetCacheStore(cacheDir: workDir, maxXbrlBytes: nil)
        let client = EdinetAPIClient(
            apiKey: nil, cacheStore: store, xbrlObjectStore: R2XbrlObjectStore(config: config))
        let useFake = env["BLT_SEGMENT_INFO_SCAN_FAKE"] == "1"
        let segmentDecider: any SegmentInfoDeciding
        let columnDecider: any RevenueRecognitionColumnDeciding
        if useFake {
            let fake = FakeRevenueRecognitionColumnDecider()
            segmentDecider = fake
            columnDecider = fake
        } else {
            let decisions = OpenRouterDecisionsClient(endpoint: endpoint)
            segmentDecider = OpenRouterSegmentInfoDecider(client: decisions)
            columnDecider = OpenRouterRevenueRecognitionColumnDecider(client: decisions)
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
        var errors: [[String: Any]] = []

        for row in rows {
            guard let xbrlDir = xbrlDirs[row.docID] else {
                errors.append(["code": row.code, "doc_id": row.docID, "why": "xbrl_missing"])
                continue
            }
            let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)
            let denom = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
                xbrlDir: xbrlDir, tables: segments.tables)
            let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
                segments: segments, consolidatedSales: denom.value,
                client: UnavailableChatClient(),
                labelsByTag: XBRLUtils.loadLabelsByTag(in: xbrlDir),
                denominatorTag: denom.tag,
                columnDecider: columnDecider,
                segmentInfoDecider: segmentDecider,
                fiscalYearEnd: BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir),
                docID: row.docID)

            var comparison = compare(prod: row, snapshot: snapshot, source: source, audit: audit)
            comparison.record["extract_method"] = segments.method
            comparison.record["table_count"] = segments.tables.count
            comparison.record["headings"] = segments.tables.map { $0.heading }
            if let denom = row.denominator {
                comparison.record["prod_denominator"] = denom
            }
            if let denom = snapshot?.denominator {
                comparison.record["new_denominator"] = denom
            }
            if let reason = audit?.notApplicableReason {
                comparison.record["not_applicable"] = reason
            }
            if !store.hasXbrlDir(row.docID, saveDir: workDir) {
                comparison.record["xbrl_status"] = "missing_on_disk"
            } else if segments.method == "not_found" && segments.tables.isEmpty {
                comparison.record["xbrl_status"] = "extract_empty"
            } else {
                comparison.record["xbrl_status"] = "ok"
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

        let sample = Array(changed.prefix(25))
        var whyCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        var headingCounts: [String: Int] = [:]
        for item in changed {
            let why = (item["why"] as? String).flatMap {
                $0.split(separator: " | ").first.map(String.init)
            } ?? ""
            whyCounts[why, default: 0] += 1
            sourceCounts[item["source"] as? String ?? "", default: 0] += 1
            let heads = (item["headings"] as? [String] ?? []).joined(separator: ",")
            headingCounts[heads.isEmpty ? "(none)" : heads, default: 0] += 1
        }
        var xbrlStatusCounts: [String: Int] = [:]
        for item in same + changed + errors {
            let status = item["xbrl_status"] as? String ?? "unknown"
            xbrlStatusCounts[status, default: 0] += 1
        }
        let newlyClean = (same + changed).filter {
            ($0["prod_needs_review"] as? Bool) == true
                && ($0["new_needs_review"] as? Bool) == false
        }
        let artifact: [String: Any] = [
            "prod_row_count": rows.count,
            "companies": Set(rows.map(\.code)).count,
            "same": same.count,
            "changed": changed.count,
            "now_needs_review": nowNeedsReview.count,
            "errors": errors.count,
            "missing_xbrl": missingXbrl,
            "missing_xbrl_count": missingXbrl.count,
            "xbrl_status_counts": xbrlStatusCounts,
            "newly_clean_count": newlyClean.count,
            "newly_clean": newlyClean,
            "why_counts": whyCounts,
            "changed_source_counts": sourceCounts,
            "changed_heading_counts": headingCounts,
            "sample_changed": sample,
            "changed_records": changed,
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
            segment-info Jev scan same=\(same.count) changed=\(changed.count) \
            now_needs_review=\(nowNeedsReview.count) errors=\(errors.count)
            """.utf8))
        #expect(errors.count < rows.count || rows.isEmpty)
    }

    private func compare(
        prod: SegmentInfoProdRow,
        snapshot: BreakdownSnapshot?,
        source: BusinessBreakdownSource,
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

        let newLabels = snapshot.rows.filter { $0.rowKind == "segment" }.map { $0.labelRaw }.sorted()
        var amountMismatches: [String] = []
        for label in Set(prodLabels).union(newLabels) {
            let old = prodAmounts[label]
            let new = snapshot.rows.first { $0.labelRaw == label && $0.rowKind == "segment" }?.amount
            if let old, let new {
                if abs(old - new) > max(1.0, abs(old) * 1e-6) {
                    amountMismatches.append(
                        "\(label) prod=\(old) new=\(new)")
                }
            } else if old != nil || new != nil {
                amountMismatches.append("\(label) prod=\(old as Any) new=\(new as Any)")
            }
        }

        var reasons: [String] = []
        if source != .segmentInfoLLM {
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
        if snapshot.warnings.contains(SegmentInfoLLMNormalizer.warningGeographyTaken) {
            reasons.append("geography_only_taken")
        }

        let record: [String: Any] = [
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
