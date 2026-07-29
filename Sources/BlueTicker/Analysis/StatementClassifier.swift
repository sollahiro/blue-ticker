// Stage 7（Statement 本体）の BS/PL/CF 判定・抽出。docs/statement-normalization-concept.md 参照。
//
// XBRLUtils.collectAllNumericFacts が既に付与している role/label メタデータを使い、
// タグを事前に決め打ちせず（企業拡張タグも含め）BS/PL/CF へ振り分ける。実データ検証
// （キャッシュ済み実XBRL 158社、J-GAAP/IFRS 混在）で以下のキーワード判定に収束することを確認済み。

/// Statement 本体が対象とする財務諸表の種類。
public enum StatementSectionType: String, CaseIterable, Sendable {
    case balanceSheet
    case incomeStatement
    case cashFlow
}

enum StatementClassifier {
    /// role URI から BS/PL/CF のいずれかを判定する。注記・補足表（`Notes` 接頭辞）は対象外（nil）。
    /// 複数キーワードに一致する事態は実データ上確認されていないため、判定順は固定（BS→PL→CF）。
    static func classify(role: String) -> StatementSectionType? {
        let name = XBRLUtils.sectionNameFromRole(role)
        guard !name.hasPrefix(Xbrl.statementNotesRolePrefix) else { return nil }

        if Xbrl.balanceSheetRoleKeywords.contains(where: { name.contains($0) }) {
            return .balanceSheet
        }
        if Xbrl.incomeStatementRoleKeywords.contains(where: { name.contains($0) }) {
            return .incomeStatement
        }
        if Xbrl.cashFlowRoleKeywords.contains(where: { name.contains($0) }) {
            return .cashFlow
        }
        return nil
    }

    /// fact index から指定した statement type の当期・行一覧を抽出する。
    ///
    /// 連結優先・非連結フォールバック（`ContextHelpers` 既存ロジックを流用。学び: Breakdown Stage 6
    /// と同じく、子会社を持たない小規模企業は連結コンテキストを持たない）。表示順は presentation
    /// linkbase の並び順（`XbrlFact.orderByRole`）を使い、取得できないタグはタグ名のアルファベット順を
    /// 決定的なフォールバックとする（末尾の `sorted` 参照）。
    static func extractLineItems(
        from facts: XbrlFactIndex, sectionType: StatementSectionType
    ) -> [StatementLineItem] {
        let isInstant = sectionType == .balanceSheet
        let primaryRole = primaryRole(for: facts, sectionType: sectionType)
        var consolidated: [StatementLineItem] = []
        var nonConsolidated: [StatementLineItem] = []

        for (tag, ctxMap) in facts {
            for (ctx, fact) in ctxMap {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                guard roles.contains(where: { classify(role: $0) == sectionType }) else { continue }

                // 非連結側は isNonConsolidatedInstant/Duration ではなく isPureNonConsolidatedContext
                // を使う（`_NonConsolidatedMember` に続けてセグメント軸メンバーが付いた
                // dimensioned context を弾く。isNonConsolidatedInstant/Duration には
                // isConsolidatedInstant/Duration にある `!ctx.hasSuffix("Member")` 相当の
                // ガードが無く、素通しすると同一タグに複数のセグメント別値が紛れ込む）。
                let patterns = isInstant ? Xbrl.instantContextPatterns : Xbrl.durationContextPatterns
                let isConsolidated: Bool
                let isNonConsolidated: Bool
                if isInstant {
                    isConsolidated = ContextHelpers.isConsolidatedInstant(ctx)
                } else {
                    isConsolidated = ContextHelpers.isConsolidatedDuration(ctx)
                }
                isNonConsolidated = ContextHelpers.isPureNonConsolidatedContext(ctx, patterns: patterns)
                guard isConsolidated || isNonConsolidated else { continue }

                let order = primaryRole.flatMap { fact.orderByRole?[$0] }
                let item = StatementLineItem(
                    tag: tag, label: fact.label, value: fact.value, unit: fact.unitRef, order: order)
                if isConsolidated {
                    consolidated.append(item)
                } else {
                    nonConsolidated.append(item)
                }
            }
        }

        let chosen = consolidated.isEmpty ? nonConsolidated : consolidated
        // presentation linkbase の表示順が取れたタグを優先し、取れないタグはタグ名のアルファベット順へ
        // フォールバックする（両方 order 無しの場合は従来どおりタグ名順のみで決定的）。
        return chosen.sorted { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (l?, r?): return l == r ? lhs.tag < rhs.tag : l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.tag < rhs.tag
            }
        }
    }

    /// sectionType へ分類される role のうち、facts の中で最も多くのタグが属する role を1つ選ぶ。
    ///
    /// 表示順（`order`）は同一 role（presentation tree）内でしか比較できない。IFRS 企業では
    /// 「損益計算書」と「包括利益計算書」のように sectionType が同じでも role が複数存在し、
    /// 一部タグ（当期純利益等）は両方に現れる。role を tag ごとに別々に選ぶと、異なる木の
    /// order 値が混ざって表示順が破綻する（実データ検証で確認）ため、書類全体で単一の role に固定する。
    /// 同数の場合は role 名の昇順で決定的に選ぶ。
    private static func primaryRole(for facts: XbrlFactIndex, sectionType: StatementSectionType) -> String? {
        var frequency: [String: Int] = [:]
        for (_, ctxMap) in facts {
            for (_, fact) in ctxMap {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                for r in roles where classify(role: r) == sectionType {
                    frequency[r, default: 0] += 1
                }
            }
        }
        return frequency.keys.min { a, b in
            let fa = frequency[a] ?? 0
            let fb = frequency[b] ?? 0
            return fa == fb ? a < b : fa > fb
        }
    }
}
