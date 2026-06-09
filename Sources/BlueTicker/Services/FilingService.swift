import Foundation

// Port of the search_filings portion of blue_ticker/services/filing_service.py
// (XBRL section extraction is Phase 3)

struct FilingService {
    let edinetClient: EdinetAPIClient

    /// EDINET 書類を検索して返す。
    /// docTypes: 取得する書類種別（省略時は全種別）
    /// maxDocuments: 返却件数上限
    func searchFilings(
        code: String,
        maxYears: Int = 10,
        docTypes: [String]? = nil,
        maxDocuments: Int = 10
    ) async -> [[String: Any]] {
        let requested = Set(docTypes ?? [])
        let fetchAnnual = requested.isEmpty || !requested.isDisjoint(with: ["120", "130"])
        let fetchHalf = requested.isEmpty || !requested.isDisjoint(with: ["140", "160"])

        // 年次書類を取得（半期検索でも内部的に使うため、どちらかが true なら呼ぶ）
        var annualDocs: [[String: Any]] = []
        if fetchAnnual || fetchHalf {
            annualDocs = await EdinetDiscovery.buildDocumentIndexForCode(
                code: code, client: edinetClient, analysisYears: maxYears
            )
        }

        var docs: [[String: Any]] = fetchAnnual ? annualDocs : []

        if fetchHalf {
            let halfDocs = await EdinetDiscovery.buildHalfYearDocumentIndexForCode(
                code: code, client: edinetClient, analysisYears: maxYears,
                prebuiltAnnualDocs: annualDocs
            )
            docs.append(contentsOf: halfDocs)
        }

        if !requested.isEmpty {
            docs = docs.filter { requested.contains($0["docTypeCode"] as? String ?? "") }
        }

        // 重複除去 + 提出日時降順 + maxDocuments 件
        var seen = Set<String>()
        var unique: [[String: Any]] = []
        for doc in docs.sorted(by: { ($0["submitDateTime"] as? String ?? "") > ($1["submitDateTime"] as? String ?? "") }) {
            guard let docID = doc["docID"] as? String, !docID.isEmpty, !seen.contains(docID) else { continue }
            seen.insert(docID)
            unique.append(doc)
            if unique.count >= maxDocuments { break }
        }
        return unique
    }
}
