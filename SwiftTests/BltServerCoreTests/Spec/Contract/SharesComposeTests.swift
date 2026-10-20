// `shares` の公開契約 {code, doc_id, items}。格納済み2注記の読み取り結果からの組み立てを見る。
// 注記の抽出そのものは `RealXbrlStatementNotesTests` 側。

import Foundation
import Testing

@testable import BltServerCore
@testable import BlueTickerCore

private func perShareFound(docID: String) -> StatementNoteLoadResult {
    .found([
        "code": "6758",
        "doc_id": docID,
        "note_type": statementNoteTypePerShareInformation,
        "note": [
            "items": [
                ["tag": "eps", "label": "１株当たり当期純利益", "value": -54.7, "unit": "yen_per_share"],
                ["tag": "diluted_eps", "label": "潜在株式調整後１株当たり当期純利益", "value": -54.36,
                 "unit": "yen_per_share"],
                ["tag": "bps", "label": "１株当たり親会社株主持分", "value": 1374.32, "unit": "yen_per_share"],
            ]
        ] as [String: Any],
    ])
}

private func issuedFound(docID: String) -> StatementNoteLoadResult {
    .found([
        "code": "6758",
        "doc_id": docID,
        "note_type": statementNoteTypeIssuedSharesAndCapital,
        "note": [
            "as_of_period_end": ["issued_shares": 6_149_810_645.0] as [String: Any],
        ] as [String: Any],
    ])
}

private func foundBody(_ result: StatementNoteLoadResult) -> [String: Any]? {
    if case .found(let body) = result { return body }
    return nil
}

private func keys(_ body: [String: Any]) -> [String] {
    (body["items"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
}

@Suite struct SharesComposeTests {
    @Test func bothNotesComposeOneDocument() throws {
        let result = composeShares(
            perShare: perShareFound(docID: "S100YE2C"), issuedShares: issuedFound(docID: "S100YE2C"))
        let body = try #require(foundBody(result))
        #expect(body["code"] as? String == "6758")
        #expect(body["doc_id"] as? String == "S100YE2C")
        #expect(keys(body) == ["eps", "diluted_eps", "bps", "issued_shares"])
        let items = try #require(body["items"] as? [[String: Any]])
        #expect(items[3]["value"] as? Double == 6_149_810_645)
        #expect(items[3]["unit"] as? String == "shares")
        // 資本金・推移の表・note_type は返さない
        #expect(body["note"] == nil)
        #expect(body["note_type"] == nil)
    }

    @Test func issuedSharesFromAnotherDocumentIsNotMixed() throws {
        let result = composeShares(
            perShare: perShareFound(docID: "S100YE2C"), issuedShares: issuedFound(docID: "S100OLD1"))
        let body = try #require(foundBody(result))
        #expect(body["doc_id"] as? String == "S100YE2C")
        #expect(keys(body) == ["eps", "diluted_eps", "bps"])
    }

    @Test func issuedSharesAloneIsServed() throws {
        let result = composeShares(
            perShare: .notApplicable(reason: statementNoteNotApplicableNotFound),
            issuedShares: issuedFound(docID: "S100YE2C"))
        let body = try #require(foundBody(result))
        #expect(keys(body) == ["issued_shares"])
    }

    @Test func noValuesKeepsPerShareReason() {
        let result = composeShares(
            perShare: .notApplicable(reason: statementNotApplicableUSGAAP), issuedShares: .absent)
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected notApplicable")
            return
        }
        #expect(reason == statementNotApplicableUSGAAP)
    }

    @Test func nothingStoredIsAbsent() {
        guard case .absent = composeShares(perShare: .absent, issuedShares: .absent) else {
            Issue.record("expected absent")
            return
        }
    }
}
