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
    /// 決定的なフォールバックとする（末尾の `sorted` 参照）。`parentTagsByRoleTag`
    /// （`XBRLUtils.loadPresentationParents`）を渡すと BS/CF 行に `section`（資産/負債/純資産、
    /// 営業/投資/財務）を付与する。省略時（テスト等）は常に nil。
    static func extractLineItems(
        from facts: XbrlFactIndex, sectionType: StatementSectionType,
        parentTagsByRoleTag: [String: [String: Set<String>]] = [:]
    ) -> [StatementLineItem] {
        let isInstant = sectionType == .balanceSheet
        var consolidated: [(tag: String, fact: XbrlFact)] = []
        var nonConsolidated: [(tag: String, fact: XbrlFact)] = []

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

                if isConsolidated {
                    consolidated.append((tag, fact))
                } else {
                    nonConsolidated.append((tag, fact))
                }
            }
        }

        let chosen = consolidated.isEmpty ? nonConsolidated : consolidated
        let primaryRole = primaryRole(coveringTagsOf: chosen, sectionType: sectionType)
        let parentTagsByTag = primaryRole.flatMap { parentTagsByRoleTag[$0] }
        let items = chosen.map { tag, fact in
            let order = primaryRole.flatMap { fact.orderByRole?[$0] }
            let section = parentTagsByTag.flatMap {
                lineSection(for: tag, sectionType: sectionType, parentTagsByTag: $0)
            }
            return StatementLineItem(
                tag: tag, label: fact.label, value: fact.value, unit: fact.unitRef, order: order,
                section: section)
        }

        // presentation linkbase の表示順が取れたタグを優先し、取れないタグはタグ名のアルファベット順へ
        // フォールバックする（両方 order 無しの場合は従来どおりタグ名順のみで決定的）。
        return items.sorted { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (l?, r?): return l == r ? lhs.tag < rhs.tag : l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.tag < rhs.tag
            }
        }
    }

    /// sectionType へ分類される role のうち、実際に採用された（連結優先／非連結フォールバック後の）
    /// タグ集合を最も多くカバーする role を1つ選ぶ。
    ///
    /// 表示順（`order`）は同一 role（presentation tree）内でしか比較できない。IFRS 企業では
    /// 連結BS用role（例: `ConsolidatedStatementOfFinancialPositionIFRS`）とは別に、個別（非連結）
    /// BS用role（例: `BalanceSheet`、J-GAAPタグ体系）が同じ sectionType に分類されることがある。
    /// **fact の出現頻度で role を選ぶと誤る**（実データ検証で発見: 個別BS用roleは非連結・複数年度分の
    /// factを大量に含むため頻度で勝つが、そのroleの木には採用済みの連結IFRSタグが1つも含まれず、
    /// 全行のorderがnilになりアルファベット順へサイレント劣化していた）。正しい基準は「採用済みタグを
    /// 実際にどれだけ説明できるか（カバレッジ）」であり、頻度ではない。同数の場合は role 名の昇順で
    /// 決定的に選ぶ。
    private static func primaryRole(
        coveringTagsOf items: [(tag: String, fact: XbrlFact)], sectionType: StatementSectionType
    ) -> String? {
        var candidateRoles: Set<String> = []
        for (_, fact) in items {
            let roles = fact.roles ?? fact.role.map { [$0] } ?? []
            for r in roles where classify(role: r) == sectionType {
                candidateRoles.insert(r)
            }
        }

        func coverage(_ role: String) -> Int {
            items.reduce(into: 0) { count, item in
                if item.fact.orderByRole?[role] != nil { count += 1 }
            }
        }
        return candidateRoles.min { a, b in
            let ca = coverage(a)
            let cb = coverage(b)
            return ca == cb ? a < b : ca > cb
        }
    }

    /// presentation 祖先タグを辿り、BS は資産/負債/純資産、CF は営業/投資/財務へ分類する。
    ///
    /// タグそのものではなく祖先を判定に使う理由: 個々の明細タグ名（例: `CashAndDeposits`）は
    /// 区分を表す語を含まないことが多く、区分は presentation linkbase 上の親子関係（例:
    /// `CashAndDeposits` → `CurrentAssetsAbstract` → `AssetsAbstract`）でのみ判定できる
    /// （`docs/statement-normalization-concept.md`）。`parentTagsByTag` は同一タグが役割内で
    /// 複数回参照される場合に複数の親を持ちうるため、BFS で全経路を辿り最初に一致した祖先で確定する。
    private static func lineSection(
        for tag: String, sectionType: StatementSectionType, parentTagsByTag: [String: Set<String>]
    ) -> StatementLineSection? {
        guard sectionType != .incomeStatement else { return nil }

        var frontier: Set<String> = [tag]
        var visited: Set<String> = []
        while !frontier.isEmpty {
            var nextFrontier: Set<String> = []
            for current in frontier {
                guard !visited.contains(current) else { continue }
                visited.insert(current)
                for parent in parentTagsByTag[current] ?? [] {
                    if let section = classifyAncestor(parent, sectionType: sectionType) {
                        return section
                    }
                    nextFrontier.insert(parent)
                }
            }
            frontier = nextFrontier
        }
        return nil
    }

    /// 単一の祖先タグ名を区分キーワードへ照合する。判定順は `Constants/Xbrl.swift` のコメント参照
    /// （BS は NetAssets/Equity → Liabilit → Asset の順が必須）。
    private static func classifyAncestor(
        _ ancestorTag: String, sectionType: StatementSectionType
    ) -> StatementLineSection? {
        switch sectionType {
        case .balanceSheet:
            if Xbrl.statementNetAssetsAncestorKeywords.contains(where: { ancestorTag.contains($0) }) {
                return .netAssets
            }
            if Xbrl.statementLiabilitiesAncestorKeywords.contains(where: { ancestorTag.contains($0) }) {
                return .liabilities
            }
            if Xbrl.statementAssetsAncestorKeywords.contains(where: { ancestorTag.contains($0) }) {
                return .assets
            }
            return nil
        case .cashFlow:
            if Xbrl.statementOperatingAncestorKeywords.contains(where: { ancestorTag.contains($0) }) {
                return .operating
            }
            if Xbrl.statementInvestingAncestorKeywords.contains(where: { ancestorTag.contains($0) }) {
                return .investing
            }
            if Xbrl.statementFinancingAncestorKeywords.contains(where: { ancestorTag.contains($0) }) {
                return .financing
            }
            return nil
        case .incomeStatement:
            return nil
        }
    }
}
