import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// 格納済み Overview を code で引く。read 床以上かつ applicable・ok な本文があるときだけ返す。
/// 無い・床未満・対象外・生成失敗は nil（呼び出し側 404。ライブ生成へはフォールバックしない）。
package func loadStoredOverview(code: String, db: Database) async throws -> [String: Any]? {
    guard let row = try await CompanyOverview.find(code, on: db),
        isServableCompanyOverviewCacheVersion(row.cacheVersion),
        row.payload.ok,
        row.payload.applicable
    else { return nil }
    let text = row.payload.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return companyOverviewServeJSON(code: row.id ?? code, overview: text, docID: row.docID)
}
