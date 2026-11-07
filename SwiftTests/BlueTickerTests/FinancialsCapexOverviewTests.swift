// financials の capex を breakdown capex 軸の本文由来の総額で置き換える純粋関数の検証。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct FinancialsCapexOverviewTests {
    private func response(_ years: [(docID: String, capex: Double?)]) -> FinancialsComputeResult {
        var out = FinancialsResponse(
            schemaVersion: 5, code: "2172", name: "", sector: "", market: "", currency: "JPY",
            unit: "百万円", years: [])
        out.years = years.map {
            var year = FinancialsYear()
            year.docId = $0.docID
            year.capex = $0.capex
            return year
        }
        return .success(out)
    }

    private func capexes(_ result: FinancialsComputeResult) -> [Double?] {
        guard case .success(let r) = result else { return [] }
        return r.years.map(\.capex)
    }

    @Test func replacesOnlyTheMatchingDocWithProseTotalInMillionYen() {
        let result = response([("S100Z4PA", 6.015), ("S100WRCI", 38.923)])
        let out = applyingBreakdownCapexProseOverview(
            to: result, overviewYenByDocID: ["S100Z4PA": 7_350_000])
        #expect(capexes(out) == [7.35, 38.923])
    }

    @Test func ignoresNonPositiveAndMissing() {
        let result = response([("S100Z4PA", 6.015)])
        #expect(capexes(applyingBreakdownCapexProseOverview(
            to: result, overviewYenByDocID: ["S100Z4PA": 0])) == [6.015])
        #expect(capexes(applyingBreakdownCapexProseOverview(
            to: result, overviewYenByDocID: [:])) == [6.015])
    }

    @Test func usesOnlyCapexProseDenominators() {
        func payload(tag: String) -> BreakdownSnapshotPayload {
            BreakdownSnapshotPayload(
                axis: breakdownAxisCapex, denominator: 0, denominatorTag: tag, rows: [],
                sourceKind: breakdownSourceCapexProse, needsReview: false, warnings: [],
                capitalExpendituresOverview: CapexMetricTotalsPayload(
                    denominator: 7_350_000, denominatorTag: tag))
        }
        #expect(capexProseOverviewYen(in: payload(tag: breakdownDenominatorTagCapexProse)) == 7_350_000)
        #expect(capexProseOverviewYen(in: payload(tag: "OverviewOfCapitalExpendituresEtc")) == nil)
    }
}
