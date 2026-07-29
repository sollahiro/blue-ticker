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
    /// と同じく、子会社を持たない小規模企業は連結コンテキストを持たない）。表示順（presentation
    /// linkbase の並び順）は現状取得できないため、タグ名のアルファベット順を暫定の決定的順序とする
    /// （docs/statement-normalization-concept.md「未決事項」）。
    static func extractLineItems(
        from facts: XbrlFactIndex, sectionType: StatementSectionType
    ) -> [StatementLineItem] {
        let isInstant = sectionType == .balanceSheet
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

                let item = StatementLineItem(
                    tag: tag, label: fact.label, value: fact.value, unit: fact.unitRef, order: nil)
                if isConsolidated {
                    consolidated.append(item)
                } else {
                    nonConsolidated.append(item)
                }
            }
        }

        let chosen = consolidated.isEmpty ? nonConsolidated : consolidated
        return chosen.sorted { $0.tag < $1.tag }
    }
}
