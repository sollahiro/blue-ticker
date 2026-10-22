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

    /// 旧版の推移の表の円単位だけが原因の要確認行は、発行済株式数（タグ）を止めない。
    @Test func legacyTableUnitWarningDoesNotWithholdShareCount() {
        let unit = legacyIssuedSharesUnitUnresolvedWarning
        #expect(isServableIssuedSharesForShares(needsReview: false, warnings: []))
        #expect(isServableIssuedSharesForShares(needsReview: true, warnings: [unit]))
        #expect(!isServableIssuedSharesForShares(needsReview: true, warnings: []))
        #expect(!isServableIssuedSharesForShares(needsReview: true, warnings: [unit, "other"]))
        #expect(!isPubliclyServableStatementNote(needsReview: true, warnings: [unit]))
    }

    private static func incomeLine(_ tag: String, _ value: Double, unit: String = "JPYPerShares") -> StatementLineItem {
        StatementLineItem(tag: tag, label: nil, value: value, unit: unit, order: nil)
    }

    /// 継続・非継続は同じ書類の格納済み statement から、基本的／希薄化後それぞれの直後に入る。
    // source: code=6758 fy_end=2026-03-31 doc_id=S100YE2C page=130 field=shares.continuing_eps
    @Test func continuingAndDiscontinuedFollowTheirParent() throws {
        let income = [
            Self.incomeLine("ContinuingOperationsBasicEarningsLossPerShareIFRS", 172.51),
            Self.incomeLine("DiscontinuedOperationsBasicEarningsLossPerShareIFRS", -227.21),
            Self.incomeLine("ContinuingOperationsDilutedEarningsLossPerShareIFRS", 171.44),
            Self.incomeLine("DiscontinuedOperationsDilutedEarningsLossPerShareIFRS", -225.8),
        ]
        let result = composeShares(
            perShare: perShareFound(docID: "S100YE2C"), issuedShares: issuedFound(docID: "S100YE2C"),
            incomeStatement: income)
        let body = try #require(foundBody(result))
        #expect(
            keys(body) == [
                "eps", "continuing_eps", "discontinued_eps", "diluted_eps", "continuing_diluted_eps",
                "discontinued_diluted_eps", "bps", "issued_shares",
            ])
        let items = try #require(body["items"] as? [[String: Any]])
        #expect(items[1]["value"] as? Double == 172.51)
        #expect(items[1]["label"] as? String == "継続事業の基本的１株当たり当期利益")
        #expect(items[5]["value"] as? Double == -225.8)
        #expect(items[5]["unit"] as? String == "yen_per_share")
    }

    @Test func operationsSplitNeedsParentAndYen() throws {
        // 親（eps）が無ければ内訳だけを浮かせない。円以外の単位は混ぜない。
        let result = composeShares(
            perShare: .absent, issuedShares: issuedFound(docID: "S100YE2C"),
            incomeStatement: [Self.incomeLine("ContinuingOperationsBasicEarningsLossPerShareIFRS", 1)])
        #expect(keys(try #require(foundBody(result))) == ["issued_shares"])
        let usd = composeShares(
            perShare: perShareFound(docID: "S100YE2C"), issuedShares: .absent,
            incomeStatement: [
                Self.incomeLine("ContinuingOperationsBasicEarningsLossPerShareIFRS", 1, unit: "USDPerShares")
            ])
        #expect(keys(try #require(foundBody(usd))) == ["eps", "diluted_eps", "bps"])
    }
}
