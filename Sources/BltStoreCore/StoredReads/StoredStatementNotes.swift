import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// `loadStoredStatementNote` の結果3値。`BreakdownLoadResult`（内訳取り込み）と同型
/// （「行が無い/read不可」と「行はあるが対象外だった（reason付き）」を区別する）。
package enum StatementNoteLoadResult {
    /// 実データあり。公開契約 {code, doc_id, note_type, note} の JSON。
    case found([String: Any])
    /// 行はあるが当該 note_type が対象外だった（`statementNoteNotApplicable*` のいずれか）。
    case notApplicable(reason: String)
    /// 行が無い、または read 不可（バージョン床未満等）。
    case absent
}

/// 格納済み 財務諸表注記取り込み 注記を引いて公開契約 {code, doc_id, note_type, note} を返す。
/// `noteType` は `statementNoteType*` 定数のいずれか（未知の note_type は absent）。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新会社有報
/// （提出日時降順のうち read 可能・会社開示府令の先頭）。特定有価証券府令(030)は選ばない。
/// read 可否は `isServableStatementNote`（xbrl_facts/not_applicable はバージョン床、LLM 経由は常に可）。
/// 無い・read 不可・府令対象外なら `.absent`（呼び出し側は 404。ライブ解決へはフォールバックしない）。
package func loadStoredStatementNote(
    code: String, docId: String?, noteType: String, db: Database,
    isPubliclyServable: (_ needsReview: Bool, _ warnings: [String]) -> Bool = {
        isPubliclyServableStatementNote(needsReview: $0, warnings: $1)
    }
) async throws -> StatementNoteLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    // 未公開 note_type（例: sga_expense_breakdown）は cache_version があっても配信しない。
    guard isKnownStatementNoteType(noteType) else { return .absent }
    guard !statementNoteCacheVersion(forType: noteType).isEmpty else { return .absent }

    let row: CompanyStatementNote?
    if let docId, !docId.isEmpty {
        guard try await isCompanyDisclosureDoc(docID: docId, db: db) else { return .absent }
        let key = CompanyStatementNote.compositeID(docID: docId, noteType: noteType)
        let found = try await CompanyStatementNote.find(key, on: db)
        row = (found?.code == code4) ? found : nil
    } else {
        let candidates = try await CompanyStatementNote.query(on: db)
            .filter(\.$code == code4)
            .filter(\.$noteType == noteType)
            .sort(\.$submitDateTime, .descending)
            .all()
        let companyDocIDs = try await companyDisclosureDocIDs(
            among: candidates.map(\.docID), db: db)
        row = candidates.first {
            isServableStatementNote(source: $0.source, cacheVersion: $0.cacheVersion, noteType: noteType)
                && isPubliclyServable($0.needsReview, $0.payload.warnings)
                && companyDocIDs.contains($0.docID)
        }
    }

    guard let row,
        isServableStatementNote(source: row.source, cacheVersion: row.cacheVersion, noteType: noteType),
        isPubliclyServable(row.needsReview, row.payload.warnings),
        let docID = row.id?.components(separatedBy: "#").first
    else { return .absent }

    if let reason = row.notApplicableReason {
        return .notApplicable(reason: reason)
    }

    return .found([
        "code": code4,
        "doc_id": docID,
        "note_type": row.noteType,
        "note": row.payload.jsonObject(),
    ])
}

/// 格納済みの2注記（`per_share_information` / `issued_shares_and_capital`）から公開契約
/// {code, doc_id, items} を組み立てる。書類は 1株当たり情報の行に揃える（doc_id 省略時はその最新）。
/// 1株当たり情報が無い書類だけ、発行済株式の行の書類を使う。資本金・資本準備金・推移の表は返さない。
package func loadStoredShares(code: String, docId: String?, db: Database) async throws -> StatementNoteLoadResult {
    let perShare = try await loadStoredStatementNote(
        code: code, docId: docId, noteType: statementNoteTypePerShareInformation, db: db)
    var anchorDocID = docId
    if case .found(let body) = perShare, let found = body["doc_id"] as? String {
        anchorDocID = found
    }
    let issued = try await loadStoredStatementNote(
        code: code, docId: anchorDocID, noteType: statementNoteTypeIssuedSharesAndCapital, db: db,
        isPubliclyServable: isServableIssuedSharesForShares)
    if anchorDocID == nil, case .found(let body) = issued, let found = body["doc_id"] as? String {
        anchorDocID = found
    }
    let incomeStatement = try await loadStoredStatementYear(code: code, docID: anchorDocID, db: db)?
        .incomeStatement ?? []
    return composeShares(perShare: perShare, issuedShares: issued, incomeStatement: incomeStatement)
}

/// 同じ書類の格納済み statement（read 可能な版のときだけ）。通貨や1株当たり行を引くのに使う。
package func loadStoredStatementYear(code: String, docID: String?, db: Database) async throws -> StatementYear? {
    guard let docID, let row = try await CompanyStatement.find(docID, on: db),
        row.code == String(code.prefix(4)), isServableStatementCacheVersion(row.cacheVersion)
    else { return nil }
    return row.payload
}

/// `shares` が発行済株式の注記行を使ってよいか。旧版の推移の表パーサが付けた円単位の警告
/// （`legacyIssuedSharesUnitUnresolvedWarning`）だけの要確認は、表の列の問題で期末発行済株式数
/// （タグ）には影響しないので使う。決定論の要確認行は ingest が再計算しないため、読み側で救う。
/// それ以外の要確認・回帰は従来どおり出さない。
package func isServableIssuedSharesForShares(needsReview: Bool, warnings: [String]) -> Bool {
    if isPubliclyServableStatementNote(needsReview: needsReview, warnings: warnings) { return true }
    return needsReview && !warnings.isEmpty
        && warnings.allSatisfy { $0 == legacyIssuedSharesUnitUnresolvedWarning }
}

/// 2注記の読み取り結果を `shares` の公開契約（`SharesResponse`）へ写す純関数。
/// 片方だけでも値があれば返す。どちらも値が無いときは 1株当たり情報の reason を優先する。
package func composeShares(
    perShare: StatementNoteLoadResult, issuedShares: StatementNoteLoadResult,
    incomeStatement: [StatementLineItem] = []
) -> StatementNoteLoadResult {
    var code: String?
    var docID: String?
    var items: [SharesItem] = []
    if case .found(let body) = perShare {
        code = body["code"] as? String
        docID = body["doc_id"] as? String
        let note = body["note"] as? [String: Any]
        for item in note?["items"] as? [[String: Any]] ?? [] {
            guard let key = item["tag"] as? String, let value = item["value"] as? Double else { continue }
            items.append(
                SharesItem(key: key, label: item["label"] as? String, value: value, unit: item["unit"] as? String))
        }
    }
    if case .found(let body) = issuedShares {
        let issuedDocID = body["doc_id"] as? String
        // 1株当たり情報と別書類の発行済株式は混ぜない。
        if docID == nil || docID == issuedDocID {
            let asOf = (body["note"] as? [String: Any])?["as_of_period_end"] as? [String: Any]
            if let value = asOf?["issued_shares"] as? Double {
                code = code ?? body["code"] as? String
                docID = docID ?? issuedDocID
                items.append(
                    SharesItem(
                        key: sharesIssuedSharesKey, label: sharesIssuedSharesLabel, value: value,
                        unit: sharesIssuedSharesUnit))
            }
        }
    }
    let currency = incomeStatement.lazy
        .filter { !AmountUnit.isPerShare(unitRef: $0.unit) }
        .compactMap { AmountUnit.currency(unitRef: $0.unit) }
        .first ?? AmountUnit.jpy
    // 継続・非継続は基本的／希薄化後それぞれの直後に置く。親の行が無ければ（有報に載らない等）
    // 継続・非継続も出さない（内訳だけが浮くのを避ける）。書類の通貨以外の1株当たり金額は混ぜない。
    for (tag, key, label, after) in sharesOperationsPerShareItems.reversed() {
        guard let index = items.firstIndex(where: { $0.key == after }),
            let line = incomeStatement.first(where: {
                $0.tag == tag && AmountUnit.isPerShare(unitRef: $0.unit)
                    && AmountUnit.currency(unitRef: $0.unit) == currency
            })
        else { continue }
        items.insert(SharesItem(key: key, label: label, value: line.value, unit: "yen_per_share"), at: index + 1)
    }
    if let code, let docID, !items.isEmpty {
        return .found(SharesResponse(code: code, docId: docID, currency: currency, items: items).jsonObject())
    }
    if case .notApplicable(let reason) = perShare { return .notApplicable(reason: reason) }
    if case .notApplicable(let reason) = issuedShares { return .notApplicable(reason: reason) }
    return .absent
}

/// `shares` の発行済株式数の行（`SharesItem`）の固定値。
package let sharesIssuedSharesKey = "issued_shares"

package let sharesIssuedSharesLabel = "発行済株式総数"

package let sharesIssuedSharesUnit = "shares"

/// 損益計算書の継続・非継続事業の1株当たり利益（IFRS のみタグがある）。`shares` の key と表示名。
/// 値は同じ書類の格納済み statement から取り、有報から取り直さない。
package let sharesOperationsPerShareItems: [(tag: String, key: String, label: String, after: String)] = [
    ("ContinuingOperationsBasicEarningsLossPerShareIFRS", "continuing_eps",
     "継続事業の基本的１株当たり当期利益", "eps"),
    ("DiscontinuedOperationsBasicEarningsLossPerShareIFRS", "discontinued_eps",
     "非継続事業の基本的１株当たり当期利益", "eps"),
    ("ContinuingOperationsDilutedEarningsLossPerShareIFRS", "continuing_diluted_eps",
     "継続事業の希薄化後１株当たり当期利益", "diluted_eps"),
    ("DiscontinuedOperationsDilutedEarningsLossPerShareIFRS", "discontinued_diluted_eps",
     "非継続事業の希薄化後１株当たり当期利益", "diluted_eps"),
]
