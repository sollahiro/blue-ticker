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
    /// 営業/投資/財務）を付与する。`preferredLabelByRoleTag`/`labelRoleVariantsByTag`
    /// （`XBRLUtils.loadPreferredLabelRoles`/`loadLabelRoleVariants`）を渡すと合計行・期首/期末残高等の
    /// ラベルを `preferredLabel` に応じたバリアントへ差し替える。`calculationComponentsByRoleTag`
    /// （`XBRLUtils.loadCalculationComponents`）を渡すと `is_total`/`components` を付与する
    /// （presentation の代表 role と同じ role URI を計算リンクベース側でも共有するため、
    /// `primaryRole` をそのまま流用して1つに絞る）。いずれも省略時（テスト等）は元の挙動
    /// （`section` は nil、ラベルは `fact.label` のまま、`is_total` は false）を維持する。
    static func extractLineItems(
        from facts: XbrlFactIndex, sectionType: StatementSectionType,
        parentTagsByRoleTag: [String: [String: Set<String>]] = [:],
        preferredLabelByRoleTag: [String: [String: String]] = [:],
        labelRoleVariantsByTag: [String: [String: String]] = [:],
        calculationComponentsByRoleTag: [String: [String: [CalcComponent]]] = [:]
    ) -> [StatementLineItem] {
        var consolidated: [(tag: String, fact: XbrlFact)] = []
        var nonConsolidated: [(tag: String, fact: XbrlFact)] = []

        for (tag, ctxMap) in facts {
            for (ctx, fact) in ctxMap {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                guard roles.contains(where: { classify(role: $0) == sectionType }) else { continue }

                let (isConsolidated, isNonConsolidated) = classifyContext(ctx, sectionType: sectionType)
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
        let preferredLabelRoleByTag = primaryRole.flatMap { preferredLabelByRoleTag[$0] }
        let componentsByTag = primaryRole.flatMap { calculationComponentsByRoleTag[$0] }
        let items = chosen.map { tag, fact in
            let order = primaryRole.flatMap { fact.orderByRole?[$0] }
            let section = parentTagsByTag.flatMap {
                lineSection(for: tag, sectionType: sectionType, parentTagsByTag: $0)
            }
            let label = resolvedLabel(
                for: tag, ctx: fact.contextRef, plainLabel: fact.label,
                preferredLabelRole: preferredLabelRoleByTag?[tag],
                labelRoleVariantsByTag: labelRoleVariantsByTag)
            let calcComponents = componentsByTag?[tag]
            let components = calcComponents.map {
                $0.map { StatementLineComponent(tag: $0.tag, weight: $0.weight) }
            }
            return StatementLineItem(
                tag: tag, label: label, value: fact.value, unit: fact.unitRef, order: order,
                section: section, isTotal: calcComponents != nil, components: components)
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

    /// `preferredLabel`（presentationArc 属性。合計行・期首/期末残高等でどのラベルロールを使うべきか
    /// の指示）が指すバリアントが見つかればそれを使い、無ければ通常のラベル（`fact.label`）へ
    /// フォールバックする。実データ検証: 任天堂7974 の `ValuationAndTranslationAdjustments`
    /// （`preferredLabel=totalLabel`）は通常ラベル「評価・換算差額等」ではなく合計ラベル
    /// 「評価・換算差額等合計」を使うべきケース。
    ///
    /// `CashAndCashEquivalentsIFRS` のように同一タグが同一 role 内に2回（期首残高・期末残高）
    /// 出現する場合、`preferredLabelByRoleTag` はタグ単位のためどちらか一方の preferredLabel しか
    /// 保持できない（`order`/`depth`/`parentTag` と同じ制約）。この特定パターンだけは fact 自身の
    /// context（前期末=当期首の instant か、当期末の instant か）から periodStartLabel/
    /// periodEndLabel ロールを直接選び直すことで区別する（実データ検証: トヨタ7203）。
    private static func resolvedLabel(
        for tag: String, ctx: String, plainLabel: String?, preferredLabelRole: String?,
        labelRoleVariantsByTag: [String: [String: String]]
    ) -> String? {
        let variants = labelRoleVariantsByTag[tag] ?? [:]
        if ContextHelpers.isConsolidatedPriorInstant(ctx) || ContextHelpers.isNonConsolidatedPriorInstant(ctx),
            let periodStart = variants.first(where: { $0.key.contains("periodStartLabel") })?.value {
            return periodStart
        }
        if ContextHelpers.isConsolidatedInstant(ctx) || ContextHelpers.isNonConsolidatedInstant(ctx),
            let periodEnd = variants.first(where: { $0.key.contains("periodEndLabel") })?.value {
            return periodEnd
        }
        guard let preferredLabelRole, let variant = variants[preferredLabelRole] else {
            return plainLabel
        }
        return variant
    }

    /// context がその sectionType で「連結の当期」「非連結の当期」のいずれに当たるかを判定する。
    ///
    /// BS は常に Instant、PL は常に Duration だが、CF は両方が混在する: 大半の行は Duration
    /// （フロー行）だが、現金及び現金同等物の期首/期末残高調整行は Instant 型 fact のまま CF の
    /// presentation role に現れる（実データ検証: トヨタ7203 の `CashAndCashEquivalentsIFRS` が
    /// `periodStartLabel`/`periodEndLabel` としてCF role内に2箇所出現）。CF を Duration のみで
    /// 判定すると、この Instant fact が両判定に失敗し黙って欠落する（`isConsolidatedDuration` も
    /// `isPureNonConsolidatedContext(durationContextPatterns)` も false になるため）。
    private static func classifyContext(
        _ ctx: String, sectionType: StatementSectionType
    ) -> (isConsolidated: Bool, isNonConsolidated: Bool) {
        switch sectionType {
        case .balanceSheet:
            return (
                ContextHelpers.isConsolidatedInstant(ctx),
                ContextHelpers.isPureNonConsolidatedContext(ctx, patterns: Xbrl.instantContextPatterns)
            )
        case .incomeStatement:
            return (
                ContextHelpers.isConsolidatedDuration(ctx),
                ContextHelpers.isPureNonConsolidatedContext(ctx, patterns: Xbrl.durationContextPatterns)
            )
        case .cashFlow:
            // 期首残高（periodStartLabel）は「当期首」＝前期末の instant context
            // （Prior1YearInstant 相当）で報告されるため、当期の Instant に加えて
            // 前期の Instant も CF に限り受理する。
            let isConsolidated =
                ContextHelpers.isConsolidatedDuration(ctx)
                || ContextHelpers.isConsolidatedInstant(ctx)
                || ContextHelpers.isConsolidatedPriorInstant(ctx)
            let isNonConsolidated =
                ContextHelpers.isPureNonConsolidatedContext(ctx, patterns: Xbrl.durationContextPatterns)
                || ContextHelpers.isPureNonConsolidatedContext(ctx, patterns: Xbrl.instantContextPatterns)
                || ContextHelpers.isPureNonConsolidatedContext(
                    ctx, patterns: Xbrl.priorInstantContextPatterns)
            return (isConsolidated, isNonConsolidated)
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
    /// 祖先が複数区分のキーワードに同時一致する場合（負債合計と純資産合計を束ねる見出し、例:
    /// `LiabilitiesAndEquityIFRSAbstract`）は曖昧なため確定させず、さらに上の祖先を辿り続ける
    /// （`classifyIfUnambiguous` 参照。実データ検証: デンソー6902 の `LiabilitiesIFRS` がこの
    /// 見出し直下にあり、優先順位で確定させると誤って純資産へ分類されていた）。
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
                    if let section = classifyIfUnambiguous(parent, sectionType: sectionType) {
                        return section
                    }
                    nextFrontier.insert(parent)
                }
            }
            frontier = nextFrontier
        }

        // 祖先を辿っても確定しなかった場合、タグ自身の名前が単一区分を曖昧さなく示すときに限り
        // 最後のフォールバックとして使う（実データ検証: デンソー6902 の `LiabilitiesIFRS`。直接の
        // 親 `LiabilitiesAndEquityIFRSAbstract` は負債・純資産両方のキーワードを含み祖先経由では
        // 確定できないが、タグ自身の名前は「負債」を曖昧さなく示す）。祖先の途中に単一一致する
        // ものがあればそちらが優先されるため（`InvestmentsAccountedForUsingEquityMethodIFRS` の
        // ような、"EquityMethod" 等キーワードを部分文字列として含むだけの明細タグは、祖先
        // `NonCurrentAssetsIFRSAbstract` の単一一致で先に確定しここには到達しない）、ここに来るのは
        // 祖先が曖昧または不明なタグ自身のみ。
        return classifyIfUnambiguous(tag, sectionType: sectionType)
    }

    /// 名前（祖先タグまたはタグ自身）から区分を判定する。0個一致（キーワードを含まない明細・見出し）
    /// または複数区分を束ねる見出し・グランドトータル行は nil を返す（`lineSection` 参照）。
    private static func classifyIfUnambiguous(
        _ name: String, sectionType: StatementSectionType
    ) -> StatementLineSection? {
        switch sectionType {
        case .balanceSheet:
            let matchesNetAssets = Xbrl.statementNetAssetsAncestorKeywords.contains(where: {
                name.contains($0)
            })
            let matchesLiabilities = Xbrl.statementLiabilitiesAncestorKeywords.contains(where: {
                name.contains($0)
            })
            let matchesAssets = Xbrl.statementAssetsAncestorKeywords.contains(where: { name.contains($0) })
            // 負債合計と純資産合計を束ねる見出し（例: `LiabilitiesAndEquityIFRSAbstract`）は
            // Liabilit と NetAssets/Equity の両方に一致する。これを真の曖昧さとして nil にする。
            // 一方 "NetAssetsAbstract" は NetAssets キーワード自体に "Asset" が部分文字列として
            // 含まれ Assets キーワードにも機械的に一致するが、これは意味的な曖昧さではないため
            // Liabilit との同時一致だけを曖昧さの判定基準にする（優先順位: NetAssets/Equity →
            // Liabilit → Asset。この順が必須な理由は上記の部分文字列混入のため）。
            guard !(matchesLiabilities && matchesNetAssets) else { return nil }
            if matchesNetAssets { return .netAssets }
            if matchesLiabilities { return .liabilities }
            if matchesAssets { return .assets }
            return nil
        case .cashFlow:
            let candidates: [(StatementLineSection, [String])] = [
                (.operating, Xbrl.statementOperatingAncestorKeywords),
                (.investing, Xbrl.statementInvestingAncestorKeywords),
                (.financing, Xbrl.statementFinancingAncestorKeywords),
            ]
            let matches = candidates.filter { _, keywords in keywords.contains(where: { name.contains($0) }) }
            return matches.count == 1 ? matches[0].0 : nil
        case .incomeStatement:
            return nil
        }
    }
}
