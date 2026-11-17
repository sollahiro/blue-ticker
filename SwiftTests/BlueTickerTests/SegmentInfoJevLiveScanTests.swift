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
