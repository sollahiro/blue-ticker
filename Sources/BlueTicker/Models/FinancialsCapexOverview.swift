// financials の `capex` は breakdown `capex` 軸の `capital_expenditures_overview` 分母を正本にする。
// 設備投資の概要に XBRL タグが無く本文だけの書類（`capex_prose`）は、financials の計算（XBRL のみ・
// Jev を呼ばない）では取れず CF の支出額になる。格納済みの軸の分母が本文由来のときだけ、その金額で置き換える。
// タグ由来の概要は financials が同じ XBRL から既に同じ値を解決しているので触らない。

import Foundation

/// 当該 FY（`doc_id` 一致）の capex を、格納済みの capex 軸の本文由来の総額（円）で差し替える。
/// 対応する年が無い・金額が正でないときは変えない。
public func applyingBreakdownCapexProseOverview(
    to result: FinancialsComputeResult, overviewYenByDocID: [String: Double]
) -> FinancialsComputeResult {
    guard case .success(var response) = result, !overviewYenByDocID.isEmpty else { return result }
    var changed = false
    for index in response.years.indices {
        guard let docID = response.years[index].docId,
            let yen = overviewYenByDocID[docID], yen > 0, yen.isFinite
        else { continue }
        let million = yen / Financial.millionYen
        if response.years[index].capex != million {
            response.years[index].capex = million
            changed = true
        }
    }
    return changed ? .success(response) : result
}

/// 格納済み capex 軸のペイロードから、本文由来（`capex_prose`）の会社全体総額（円）を返す。
public func capexProseOverviewYen(in payload: BreakdownSnapshotPayload) -> Double? {
    guard let overview = payload.capitalExpendituresOverview,
        overview.denominatorTag == breakdownDenominatorTagCapexProse,
        overview.denominator > 0, overview.denominator.isFinite
    else { return nil }
    return overview.denominator
}

/// 計算結果に含まれる年度の `doc_id`（格納済み breakdown の突き合わせ用）。
public func financialsDocIDs(in result: FinancialsComputeResult) -> [String] {
    guard case .success(let response) = result else { return [] }
    return response.years.compactMap(\.docId)
}
