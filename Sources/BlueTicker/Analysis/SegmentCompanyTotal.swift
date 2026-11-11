// Overview / 設備投資の会社総額。CorporateShared を会社総額にしない規則
// （日本リーテック: 全社 186 は本物の全社で、電気+兼業より小さい。荏原・資生堂は
// CorporateShared = 会社総額でカテゴリに載せない）。社名分岐は持たない。

import Foundation

enum SegmentCompanyTotal {
    /// 提案総額が全社 member と同じで、事業 member の和の方が大きいときは総額として採用しない。
    static func rejectSharedAsTotalIfOperatingLarger(
        proposed: Double, sharedAmount: Double?, operatingSum: Double
    ) -> Bool {
        guard operatingSum > 0, let sharedAmount, sharedAmount > 0 else { return false }
        let same = abs(proposed - sharedAmount) <= max(1.0, abs(sharedAmount) * 1e-9)
        return same && operatingSum > sharedAmount
    }

    /// CorporateShared / ReportableSegments が唯一の Overview member ならカテゴリ行は出さず総額だけ。
    static func isTotalOnlySoleMember(_ localName: String) -> Bool {
        localName == "CorporateSharedMember"
            || localName == "ReportableSegmentsMember"
            || localName == "TotalOfReportableSegmentsAndOthersMember"
    }

    static func operatingSum(from rows: [BreakdownRow]) -> Double {
        rows.filter { $0.rowKind == "segment" }.map(\.amount).reduce(0, +)
    }

    static func sharedAmount(from rows: [BreakdownRow]) -> Double? {
        rows.first { $0.labelRaw == "CorporateSharedMember" }?.amount
    }
}
