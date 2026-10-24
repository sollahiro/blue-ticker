import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

package func loadActiveManualXbrlOverrides(on db: Database) async throws -> [ManualXbrlOverrideRecord] {
    let rows = try await ManualXbrlOverrideRow.query(on: db)
        .filter(.sql(SQLRaw("revoked_at IS NULL")))
        .sort(\.$createdAt, .ascending)
        .all()
    return try rows.map { try $0.validatedRecord() }
}
