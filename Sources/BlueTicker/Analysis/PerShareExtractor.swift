import Foundation
import SwiftSoup

struct PerShareResult {
    var eps: Double?           // 基本1株当たり当期利益（円・連結当期）
    var issuedShares: Double?  // 発行済普通株式数（期末残高・株）
}

enum PerShareExtractor {

    /// 基本EPS（連結当期）と発行済普通株式数（期末残高）を抽出する。
    /// eps は durationFS 経由で連結 CurrentYearDuration を解決する（本表→Summary の優先順は
    /// `Xbrl.basicEpsTags`）。issuedShares は文脈・株式クラスの指定が要るため tagElements を直接参照する。
    static func extract(durationFS: FieldSet, tagElements: XbrlTagElements) -> PerShareResult {
        let eps = resolveItem(durationFS, tags: Xbrl.basicEpsTags).current
        return PerShareResult(eps: eps, issuedShares: issuedCommonSharesFYEnd(tagElements))
    }

    /// 発行済普通株式数（期末残高）。
    /// 1) 【株式の総数】表の普通株式（OrdinaryShareMember）→ 単一クラス企業の base 文脈
    /// 2) 主要な経営指標等の推移の期末発行済株式総数（CurrentYearInstant）
    private static func issuedCommonSharesFYEnd(_ el: XbrlTagElements) -> Double? {
        if let ctxs = el[Xbrl.issuedSharesFYEndTag] {
            if let v = firstContextValue(ctxs, containing: Xbrl.ordinaryShareMemberSuffix) { return v }
            if let v = ctxs[Xbrl.filingDateInstantContext] { return v }
        }
        if let ctxs = el[Xbrl.issuedSharesSummaryTag],
           let v = firstContextValue(ctxs, containing: Xbrl.currentYearInstantContext) {
            return v
        }
        return nil
    }

    /// contextRef に substring を含む最初の値を返す（辞書順で決定的に選ぶ）。
    private static func firstContextValue(_ ctxs: [String: Double], containing needle: String) -> Double? {
        for key in ctxs.keys.sorted() where key.contains(needle) {
            return ctxs[key]
        }
        return nil
    }
}
