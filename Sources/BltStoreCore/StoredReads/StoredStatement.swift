import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// 格納済み Statement 取り込み 行を code で引き、公開契約 `StatementResponse` の JSON を返す。
/// `docId` 指定時はその書類（当該 code のもの）1件のみ、省略時は当該 code の直近 `years` 件
/// （提出日時降順・床以上・会社開示府令）を束ねる。床は `statementMinServableVersion`（明示定数）。
/// 無い・床未満・対象外プレースホルダのみなら nil（呼び出し側は 404。ライブ抽出へはフォールバックしない）。
package func loadStoredStatement(
    code: String, docId: String?, years: Int, db: Database
) async throws -> [String: Any]? {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }), years > 0 else {
        return nil
    }

    let rows: [CompanyStatement]
    if let docId, !docId.isEmpty {
        // 指定書類。取り違え防止に当該 code の書類であることを確認する。
        guard let found = try await CompanyStatement.find(docId, on: db), found.code == code4,
            isServableStatementCacheVersion(found.cacheVersion),
            !isStatementNotApplicablePlaceholder(found.payload),
            try await isCompanyDisclosureDoc(docID: docId, db: db)
        else { return nil }
        rows = [found]
    } else {
        // 直近 years 件（提出日時降順のうち、read 床以上・実データ・会社開示府令）。
        let candidates = try await CompanyStatement.query(on: db)
            .filter(\.$code == code4)
            .sort(\.$submitDateTime, .descending)
            .all()
        let companyDocIDs = try await companyDisclosureDocIDs(
            among: candidates.compactMap(\.id), db: db)
        rows = Array(
            candidates
                .filter {
                    isServableStatementCacheVersion($0.cacheVersion)
                        && !isStatementNotApplicablePlaceholder($0.payload)
                        && ($0.id.map { companyDocIDs.contains($0) } ?? false)
                }
                .prefix(years))
    }
    guard !rows.isEmpty else { return nil }

    let response = StatementResponse(
        schemaVersion: statementSchemaVersion, code: code4, name: nil, sector: nil, market: nil,
        years: rows.map(\.payload))
    return response.jsonObject()
}
