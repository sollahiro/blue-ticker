import BlueTickerCore
import Fluent
import Foundation
import Logging

/// 訂正 overlay で差し戻した fact を 1 行ログする。`warnings` に `overlay_regression` が無いときは何もしない。
func logXbrlOverlayRegressionIfNeeded(
    warnings: [String], code: String, docID: String, db: Database, logger: Logger?
) async {
    guard let logger else { return }
    let parsedTokens = warnings.compactMap(parseXbrlOverlayRegressionWarning)
    guard !parsedTokens.isEmpty else { return }
    let fy = (try? await EdinetDocument.find(docID, on: db))?.periodEnd ?? ""
    for parsed in parsedTokens {
        let original = parsed.originalDocID.isEmpty ? docID : parsed.originalDocID
        var metadata: Logger.Metadata = [
            "event": "xbrl_overlay_regression",
            "code": .string(code),
            "fy": .string(fy),
            "original_doc_id": .string(original),
            "correction_doc_id": .string(parsed.correctionDocID),
            "reason": .string(parsed.kind),
        ]
        if let tag = parsed.tag { metadata["tag"] = .string(tag) }
        if let before = parsed.before { metadata["before"] = .string(before) }
        if let after = parsed.after { metadata["after"] = .string(after) }
        let reason = parsed.tag.map { "\(parsed.kind) tag=\($0)" } ?? parsed.kind
        let message = xbrlOverlayRegressionLogMessage(
            code: code, fy: fy, originalDocID: original,
            correctionDocID: parsed.correctionDocID, reason: reason)
        logger.warning("\(message)", metadata: metadata)
    }
}
