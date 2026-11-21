import BlueTickerCore
import FluentKit
import Foundation

/// 地域別売上（geography 軸）の年次推移。格納済みの複数年を正規化して返す。
/// 地域の行が無い年（same_as / not_applicable）は年に出さない。全年が空なら `.absent`。
package func loadStoredGeographyWaterfall(
    code: String, years: Int, fiscalYear: String?, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    if fiscalYear == nil, years <= 0 { return .absent }
    let snapshots = try await loadServableBreakdownYears(
        code: code4, axis: breakdownAxisGeography, db: db)
    guard !snapshots.isEmpty else { return .absent }
    let object = GeographyWaterfall.jsonObject(
        code: code4, years: snapshots, fiscalYear: fiscalYear, limit: max(1, years))
    let returned = object["years"] as? [[String: Any]] ?? []
    guard !returned.isEmpty else { return .absent }
    return .found(object)
}
