import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// 格納済み 財務取り込み 結果を code で引き、read 床以上 & 要求年数を満たすなら years に縮めた JSON を返す。
/// 床は `companyFinancialsMinServableVersion`（明示定数。現行版との完全一致ではない）。
/// 無い・床未満・年数不足なら nil（呼び出し側は 404。ライブ計算へはフォールバックしない）。
/// `years` 空（有価証券報告書未提出の notApplicable プレースホルダ、issue #86）も nil（404）とする。
/// `fields` は `years[]` 要素の射影（BLT-57）。nil なら従来どおり全キー。値・年数は変えない。
package func loadStoredFinancials(
    code: String, years: Int, fields: Set<String>? = nil, db: Database
) async throws -> [String: Any]? {
    // years <= 0 は無効要求として nil（呼び出し側 404）。空 years の 200 を返さない。
    guard years > 0,
        let row = try await CompanyFinancials.find(code, on: db),
        isServableCompanyFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= years,
        row.response.yearCount > 0
    else { return nil }
    return row.response.trimmed(toYears: years).summaryJsonObject(fields: fields)
}

/// 格納済み 財務取り込み 結果を code で引き、増減分解フィールド（`docs/financials-summary-separation.md` の Waterfall）を
/// 含めた JSON を返す。読み取り床・年数要件は `loadStoredFinancials` と同一（同じ格納行を使う。
/// 新規テーブル・cache_version は導入しない）。
package func loadStoredAnalysis(code: String, years: Int, db: Database) async throws -> [String: Any]? {
    guard years > 0,
        let row = try await CompanyFinancials.find(code, on: db),
        isServableCompanyFinancialsCacheVersion(row.cacheVersion),
        row.requestedYears >= years,
        row.response.yearCount > 0
    else { return nil }
    return row.response.trimmed(toYears: years).analysisJsonObject()
}
