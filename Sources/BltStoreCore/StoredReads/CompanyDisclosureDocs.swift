import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// `edinet_documents` 上で会社開示府令(010)の docID 集合。メタ欠落は通す（単体テストの
/// 格納行のみシードを壊さない）。メタがあり府令が 010 以外なら落とす。
package func companyDisclosureDocIDs(among docIDs: [String], db: Database) async throws -> Set<String> {
    guard !docIDs.isEmpty else { return [] }
    let metas = try await EdinetDocument.query(on: db).filter(\.$id ~~ docIDs).all()
    let metaByID = Dictionary(uniqueKeysWithValues: metas.compactMap { doc -> (String, EdinetDocument)? in
        guard let id = doc.id else { return nil }
        return (id, doc)
    })
    var allowed = Set<String>()
    for id in docIDs {
        if let meta = metaByID[id] {
            if Api.isCompanyDisclosureOrdinance(meta.ordinanceCode) { allowed.insert(id) }
        } else {
            allowed.insert(id)
        }
    }
    return allowed
}

package func isCompanyDisclosureDoc(docID: String, db: Database) async throws -> Bool {
    try await companyDisclosureDocIDs(among: [docID], db: db).contains(docID)
}
