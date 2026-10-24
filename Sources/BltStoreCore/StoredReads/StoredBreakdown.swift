import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// `loadStoredBreakdown` の結果。「行が無い/read不可」と「行はあるが product_service 軸が
/// 解決できなかった（reason付き）」と「行はあるが公開保留」を区別して呼び出し側（REST/MCP）へ伝える（issue #132）。
package enum BreakdownLoadResult {
    /// 実データあり。公開契約 {code, doc_id, axis, breakdown} の JSON。
    case found([String: Any])
    /// 行はあるが product_service 軸が解決できなかった（`breakdownNotApplicable*` のいずれか）。
    case notApplicable(reason: String)
    /// 行はあるが公開保留。interest_bearing_debt の needs_review のみ（reason は `breakdownWithheldNeedsReview`）。
    case withheld(reason: String)
    /// 行が無い、または read 不可（バージョン床未満等）。
    case absent
}

/// 格納済み 内訳取り込み 内訳を引いて公開契約 {code, doc_id, axis, breakdown} を返す。
/// axis は `isSupportedBreakdownAxis` が受け付ける軸を受け付ける
/// （geography は 2026-07-27、品質ゲート＝最新有報の needs_review=true・あいまい失敗0を確認のうえ
/// 解禁。employees / goodwill は決定論のみ。research_and_development は数値タグが無いとき
/// 本文の当期総額だけを別 Choice で補うことがある。未知の軸は absent）。
/// doc_id 指定時はその書類（当該 code のもの）、省略時は当該 code の最新会社有報
/// （提出日時降順のうち read 可能・会社開示府令の先頭）。特定有価証券府令(030)は選ばない。
/// read 可否は `isServableBreakdown`（決定論・LLM とも cache_version の床でゲート）。
/// 公開面はさらに `isPubliclyServableBreakdown`：`needs_review` / `llm_unit_unresolved` の
/// LLM 行は出さない（千円表の 1000 倍誤り stopgap。fail closed）。`revenue_recognition_llm` は
/// 単一行または明細合計 0 も出さない。残行が 0 なら `.absent`
/// （未算出と同じ 404。payload 形は変えない。最新を落としても前年へはフォールバックしない）。
/// interest_bearing_debt だけ、行が version-servable で公開除外の理由が needs_review だけのとき
/// `.withheld(needs_review)`（未算出の 404 と区別する）。他軸の公開除外は従来どおり `.absent`。
/// 無い・read 不可・府令対象外・公開除外なら `.absent`（呼び出し側は 404。ライブ解決へはフォールバックしない）。
package func loadStoredBreakdown(
    code: String, docId: String?, axis: String, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    guard isSupportedBreakdownAxis(axis) else { return .absent }

    let row: CompanyBreakdown?
    if let docId, !docId.isEmpty {
        guard try await isCompanyDisclosureDoc(docID: docId, db: db) else { return .absent }
        let key = CompanyBreakdown.compositeID(docID: docId, axis: axis)
        let found = try await CompanyBreakdown.find(key, on: db)
        row = (found?.code == code4) ? found : nil
    } else {
        let candidates = try await CompanyBreakdown.query(on: db)
            .filter(\.$code == code4)
            .filter(\.$axis == axis)
            .sort(\.$submitDateTime, .descending)
            .all()
        let companyDocIDs = try await companyDisclosureDocIDs(
            among: candidates.map(\.docID), db: db)
        row = candidates.first {
            isServableBreakdown(source: $0.source, cacheVersion: $0.cacheVersion, axis: axis)
                && companyDocIDs.contains($0.docID)
        }
    }

    guard let row, isServableBreakdown(source: row.source, cacheVersion: row.cacheVersion, axis: axis),
        let docID = row.id?.components(separatedBy: "#").first
    else { return .absent }

    let needsReview = row.needsReview || row.payload.needsReview
    guard isPubliclyServableBreakdown(
        source: row.source,
        needsReview: needsReview,
        warnings: row.payload.warnings,
        rows: row.payload.rows, axis: axis)
    else {
        // この軸だけ、行が存在し version-servable で、公開除外の理由が needs_review だけのとき reason を載せる。
        // 他軸（geography の llm_unit_unresolved 等）は従来どおり absent。
        if axis == breakdownAxisInterestBearingDebt, needsReview {
            return .withheld(reason: breakdownWithheldNeedsReview)
        }
        return .absent
    }

    if let reason = row.notApplicableReason {
        return .notApplicable(reason: reason)
    }

    var result: [String: Any] = [
        "code": code4,
        "doc_id": docID,
        "axis": row.axis,
        "breakdown": row.payload.jsonObject(),
    ]
    // LLM 経由の行のみ（xbrl_facts 経由は llmAudit が無い）。denominator_tag が
    // "income_statement.sales" 以外（例: "llm_table_subtotal"）のとき、実際の指標名を
    // notes から確認できるようにする（issue #105 のprofit指標区別ギャップ対応）。
    if let llmAudit = row.llmAudit {
        result["llm_audit"] = llmAudit.jsonObject()
    }
    return .found(result)
}
