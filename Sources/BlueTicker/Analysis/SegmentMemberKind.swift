// 報告セグメント member の種別。社名辞書は持たない。タクソノミ標準名とラベル規則。

import Foundation

enum SegmentMemberKind {
    case segment
    case reconciling
    case elimination
    case corporate
    case subtotal
    case entityTotal

    static func classify(localName: String, label: String?) -> SegmentMemberKind {
        if localName == Xbrl.entityTotalMemberName { return .entityTotal }
        if localName == "EliminationMember" || isEliminationOnly(localName: localName, label: label) {
            return .elimination
        }
        if isCorporateOnly(localName: localName, label: label) {
            return .corporate
        }
        if BreakdownMemberRoles.isReconciling(localName) { return .reconciling }
        // 「消去又は全社」「全社・消去」は消去と全社を 1 行にまとめた調整行（7203 の提出者拡張 member）。
        let compactLabel = SegmentLabelMatch.compact(label ?? "")
        if compactLabel.contains("消去"), compactLabel.contains("全社") { return .reconciling }
        if Xbrl.segmentSubtotalMemberNames.contains(localName) {
            if localName == "CorporateSharedMember" { return .corporate }
            if localName == "UnallocatedAmountsAndEliminationMember" { return .reconciling }
            return .subtotal
        }
        return .segment
    }

    static func rowKind(_ kind: SegmentMemberKind) -> String {
        switch kind {
        case .segment: return "segment"
        case .reconciling, .elimination, .corporate: return "reconciling"
        case .subtotal: return "subtotal"
        case .entityTotal: return breakdownRowKindEntityTotal
        }
    }

    static func isEliminationOnly(localName: String, label: String?) -> Bool {
        if localName == "UnallocatedAmountsAndEliminationMember" { return false }
        if localName == "ReconcilingItemsMember" { return false }
        if localName == "EliminationMember" { return true }
        if localName.contains("Elimination") && !localName.contains("Corporate")
            && !localName.contains("Unallocated") && !localName.contains("Reconciling")
        {
            return true
        }
        let compact = SegmentLabelMatch.compact(label ?? "")
        if compact.isEmpty { return false }
        if compact.contains("全社") { return false }
        return compact == "消去" || compact == "連結消去" || compact.hasSuffix("消去")
    }

    static func isCorporateOnly(localName: String, label: String?) -> Bool {
        if localName == "UnallocatedAmountsAndEliminationMember" { return false }
        if localName == "ReconcilingItemsMember" { return false }
        if localName == "CorporateMember" || localName == "CorporateSharedMember" { return true }
        if localName.contains("Corporate") && !localName.contains("Elimination") { return true }
        let compact = SegmentLabelMatch.compact(label ?? "")
        if compact.isEmpty { return false }
        if compact.contains("消去") { return false }
        return SegmentLabelMatch.isOverviewCorporateShared(compact)
    }
}
