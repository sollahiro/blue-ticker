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
        // 床判定は SQL では表現しにくいため code 単位で候補を取ってから選ぶ（社あたり直近数件）。
        // 候補はペイロード無しの軽量射影で取り、ペイロードは選んだ 1 行だけ読む（BLT-201）。
        // 同時刻の並びを決めるため doc_id 降順を第 2 キーにする。
        let candidates = try await CompanyFilingSectionsSelectionOnly.query(on: db)
            .filter(\.$code == code4)
            .sort(\.$submitDateTime, .descending)
            .sort(\.$id, .descending)
            .all()
        let companyDocIDs = try await companyDisclosureDocIDs(
            among: candidates.compactMap(\.id), db: db)
        let eligibleIDs = candidates.compactMap { candidate -> String? in
            guard let id = candidate.id, isServableFilingSectionsCacheVersion(candidate.cacheVersion),
                companyDocIDs.contains(id)
            else { return nil }
            return id
        }
        // 候補選択と本読み込みの間に ingest の purge・再抽出で行が消える／床未満になることがある。
        // そのときは次の候補へ進む（旧実装の 1 回読みで選ばれ得た書類だけを返す）。
        var selected: CompanyFilingSections?
        for id in eligibleIDs {
            if let found = try await CompanyFilingSections.find(id, on: db), found.code == code4,
                isServableFilingSectionsCacheVersion(found.cacheVersion)
            {
                selected = found
                break
            }
        }
        row = selected
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
