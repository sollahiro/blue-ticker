import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// 格納済み 有報セクション取り込み セクションを引いて公開契約 {code, doc_id, sections} を返す。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新会社有報
/// （提出日時降順のうち床以上・会社開示府令）。特定有価証券府令(030)の信託受益証券等は選ばない。
/// 床は `filingSectionsMinServableVersion`（明示定数。現行版との完全一致ではない）。
/// 無い・床未満・府令対象外なら nil（呼び出し側は 404。ライブ抽出へはフォールバックしない）。
package func loadStoredFilingSections(
    code: String, docId: String?, sections: [String]?, db: Database
) async throws -> [String: Any]? {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }

    let row: CompanyFilingSections?
    if let docId, !docId.isEmpty {
        // 指定書類。取り違え防止に当該 code の書類であることを確認する。
        let found = try await CompanyFilingSections.find(docId, on: db)
        guard found?.code == code4, try await isCompanyDisclosureDoc(docID: docId, db: db) else {
            return nil
        }
        row = found
    } else {
        // 最新会社有報（提出日時降順のうち、read 床以上・会社開示府令の先頭）。
        // 床判定は SQL では表現しにくいため code 単位で取得してから選ぶ（社あたり直近数件）。
        let candidates = try await CompanyFilingSections.query(on: db)
            .filter(\.$code == code4)
            .sort(\.$submitDateTime, .descending)
            .all()
        let companyDocIDs = try await companyDisclosureDocIDs(
            among: candidates.compactMap(\.id), db: db)
        row = candidates.first {
            isServableFilingSectionsCacheVersion($0.cacheVersion)
                && ($0.id.map { companyDocIDs.contains($0) } ?? false)
        }
    }

    guard let row, isServableFilingSectionsCacheVersion(row.cacheVersion), let docID = row.id else {
        return nil
    }
    return [
        "code": code4,
        "doc_id": docID,
        "sections": row.payload.sectionsObject(sections: sections),
    ]
}
