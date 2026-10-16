// 研究開発費の数値タグが無いとき、研究開発活動の本文から当期の会社全体の総額だけを補う。
// コードが百万円・千円・億円を円へ換算する。Jev は文の分類だけを返す。
// 1文に金額が2つある文、0円、割合だけは候補にしない。
// 確率 0.9 以上の当期総額がちょうど1文のときだけ採用する。
// セグメントへ配分できない開示は warnings に載せ、404 にはしない。
// OPENROUTER_DECISION_API_KEY が無いときは呼ばない。cache_version は上げない。
// Summary の rd は数値タグのまま（この経路は breakdown の分母だけ）。
// 文の切り出し・円換算・残り行の照合は BreakdownProseToolkit に置く。

import Foundation

typealias ResearchAndDevelopmentProseRole = BreakdownProseRole
typealias ResearchAndDevelopmentRemainderRole = BreakdownProseRemainderRole
typealias ResearchAndDevelopmentExclusionRole = BreakdownProseExclusionRole
typealias ResearchAndDevelopmentProseCandidate = BreakdownProseCandidate
typealias ResearchAndDevelopmentProseChoice = BreakdownProseChoice
typealias ResearchAndDevelopmentProseDeciding = BreakdownProseDeciding
typealias ResearchAndDevelopmentProseTotal = BreakdownProseTotal
typealias ResearchAndDevelopmentProseDecision = BreakdownProseDecision

enum ResearchAndDevelopmentProseTotalDecision {
    static let question = "research_and_development_total"
    static let maxCandidates = BreakdownProseToolkit.maxCandidates
    static let maxSentenceLength = BreakdownProseToolkit.maxSentenceLength
    static let classifyPolicy = BreakdownProseToolkit.classifyPolicy(question: question)
    static let remainderPolicy = BreakdownProseToolkit.classifyPolicy(
        question: OpenRouterResearchAndDevelopmentProseDecider.remainderQuestion)
    static let exclusionPolicy = BreakdownProseToolkit.classifyPolicy(
        question: OpenRouterResearchAndDevelopmentProseDecider.exclusionQuestion)
    static let segmentSumFarWarning = "research_and_development_segment_sum_far_from_total"

    private static let preferredPhrases = ["研究開発費"]

    static func activityPlainText(in xbrlDir: URL) -> String? {
        guard let tag = xbrlSections["research_and_development"]?.xbrlElements.first,
            let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: tag)
        else { return nil }
        let text = BreakdownProseToolkit.plainText(from: html)
        return text.isEmpty ? nil : text
    }

    static func plainText(from html: String) -> String {
        BreakdownProseToolkit.plainText(from: html)
    }

    /// 1文にちょうど1つの正の金額がある文だけ。長い文と、上限を超えたあとの文は落とす。
    /// 上限を超えるときは「研究開発費」を含む文を先に残す。`limit == nil` は上限なし（差額照合用）。
    static func candidates(in text: String, limit: Int? = maxCandidates)
        -> [ResearchAndDevelopmentProseCandidate]
    {
        BreakdownProseToolkit.candidates(
            in: text, preferredPhrases: preferredPhrases, limit: limit)
    }

    /// タグ付きの segment と reconciling が全社合計より 5% 以上少ないときの不足額。
    /// セグメント行が無い合計のみは nil（総額を残り行として二重に載せない）。
    static func shortfall(in snapshot: BreakdownSnapshot) -> Double? {
        BreakdownProseToolkit.shortfall(
            denominator: snapshot.denominator, additive: additiveSum(snapshot))
    }

    /// 百万円の丸め（日揮の 2百万円、日清製粉の 3百万円）まで。5百万円を超える相対幅は、
    /// 別セグメントの金額を同じ差額として拾う（キヤノン S100VHZZ の 50百万円差）。
    static func matchesShortfall(_ yen: Double, gap: Double) -> Bool {
        BreakdownProseToolkit.matchesShortfall(yen, gap: gap)
    }

    /// 億円表記は 0.5億円まで。332億円と注記 33,244百万円（神戸製鋼 S100OAOM）がこれ。
    static func matchesRoundedProse(_ proseYen: Double, taggedYen: Double, sentence: String)
        -> Bool
    {
        let tolerance: Double = sentence.contains("億円") ? 50_000_000 : 5_000_000
        return abs(proseYen - taggedYen) <= tolerance
    }

    /// 活動タグの全社合計が無く、採用中のタグが販管費側で、本文の研究開発費総額が
    /// 製造費用込みの注記と1文だけで一致するとき true。活動タグがある書類は対象外。
    static func confirmsManufacturingNote(
        extractedTag: String?, extractedYen: Double?, noteYen: Double?, plainText: String
    ) -> Bool {
        guard let extractedTag, Xbrl.rdExpenseJGAAPTags.contains(extractedTag),
            let extractedYen, let noteYen, noteYen > 0, extractedYen != noteYen
        else { return false }
        let matches = candidates(in: plainText, limit: nil).filter { candidate in
            candidate.sentence.contains("研究開発費")
                && matchesRoundedProse(
                    candidate.yen, taggedYen: noteYen, sentence: candidate.sentence)
                && abs(candidate.yen - noteYen) < abs(candidate.yen - extractedYen)
        }
        return matches.count == 1
    }

    static func remainderLabel(in sentence: String) -> String {
        BreakdownProseToolkit.remainderLabel(in: sentence)
    }

    /// 差額と一致する文がちょうど1つで、Jev が配分されていない残りと分類したときだけ行を足す。
    /// 5百万円で一致する文が無く、配分できない文が1つだけのときは、億円丸めで差額とずれていてもその文を見る。
    /// 足した合計がまだ 5% を超えるときは足さない。応答が無い、分類が外れたときはスナップショットを変えない。
    static func fillShortfall(
        snapshot: BreakdownSnapshot, plainText: String, code: String = "", docID: String = "",
        decider: any ResearchAndDevelopmentProseDeciding
    ) async -> (snapshot: BreakdownSnapshot, audit: SegmentNoteJevAuditPayload?) {
        guard let gap = shortfall(in: snapshot) else { return (snapshot, nil) }
        let pool = candidates(in: plainText, limit: nil)
        guard let match = BreakdownProseToolkit.matchRemainderCandidate(
            pool: pool, gap: gap,
            matchesTaggedRow: { matchesTaggedRow($0, snapshot: snapshot) })
        else { return (snapshot, nil) }
        guard let result = await BreakdownProseToolkit.acceptedClassification(
            sentence: match.sentence, policy: remainderPolicy,
            optionKeys: ResearchAndDevelopmentRemainderRole.optionKeys,
            appliedKey: ResearchAndDevelopmentRemainderRole.unallocatedRemainder,
            classify: { await decider.classifyRemainder(sentence: match.sentence) })
        else { return (snapshot, nil) }
        let filled = snapshotByAddingAdjustment(
            snapshot, yen: match.yen, label: remainderDisplayLabel(in: match.sentence),
            warning: breakdownWarningResearchAndDevelopmentProseRemainder)
        guard !filled.warnings.contains(segmentSumFarWarning) else { return (snapshot, nil) }
        return (
            filled,
            BreakdownProseToolkit.appliedSentenceAudit(
                code: code, docID: docID, axis: breakdownAxisResearchAndDevelopment,
                result: result, sentence: match.sentence, policy: remainderPolicy)
        )
    }

    static func remainderDisplayLabel(in sentence: String) -> String {
        let label = remainderLabel(in: sentence)
        if BreakdownProseToolkit.mentionsNotAllocatableToSegments(sentence),
            !label.contains("研究開発費")
        {
            return "配分不能"
        }
        return label
    }

    /// タグ付き合計が全社合計を 5% 以上超える額。
    static func excess(in snapshot: BreakdownSnapshot) -> Double? {
        BreakdownProseToolkit.excess(
            denominator: snapshot.denominator, additive: additiveSum(snapshot))
    }

    /// 総額と、その外の金額が同じ文に1組だけあるときの外の金額。
    /// 「このほか」等があり、既存行の金額そのものではない文だけ。
    static func exclusionCandidates(
        in text: String, total: Double, excess: Double
    ) -> [ResearchAndDevelopmentProseCandidate] {
        BreakdownProseToolkit.exclusionCandidates(
            in: text, excess: excess,
            matchesTotal: { yen, sentence in
                matchesRoundedProse(yen, taggedYen: total, sentence: sentence)
            },
            acceptYen: { yen in !matchesTaggedRow(yen, amounts: [total]) })
    }

    static func exclusionLabel(in sentence: String) -> String {
        BreakdownProseToolkit.exclusionLabel(in: sentence, fallback: "研究開発費に含まれない費用")
    }

    /// 総額の外と Jev が分類した金額を、負の reconciling 行として足す。既存行は削らない。
    /// 足したあとも 5% を超えるときは足さない。
    static func fillExclusion(
        snapshot: BreakdownSnapshot, plainText: String, code: String = "", docID: String = "",
        decider: any ResearchAndDevelopmentProseDeciding
    ) async -> (snapshot: BreakdownSnapshot, audit: SegmentNoteJevAuditPayload?) {
        guard let over = excess(in: snapshot) else { return (snapshot, nil) }
        let matches = exclusionCandidates(
            in: plainText, total: snapshot.denominator, excess: over)
        guard matches.count == 1, let match = matches.first else { return (snapshot, nil) }
        guard let result = await BreakdownProseToolkit.acceptedClassification(
            sentence: match.sentence, policy: exclusionPolicy,
            optionKeys: ResearchAndDevelopmentExclusionRole.optionKeys,
            appliedKey: ResearchAndDevelopmentExclusionRole.excludedFromTotal,
            classify: { await decider.classifyExclusion(sentence: match.sentence) })
        else { return (snapshot, nil) }
        let filled = snapshotByAddingAdjustment(
            snapshot, yen: -match.yen, label: exclusionLabel(in: match.sentence),
            warning: breakdownWarningResearchAndDevelopmentProseExclusion)
        guard !filled.warnings.contains(segmentSumFarWarning) else { return (snapshot, nil) }
        return (
            filled,
            BreakdownProseToolkit.appliedSentenceAudit(
                code: code, docID: docID, axis: breakdownAxisResearchAndDevelopment,
                result: result, sentence: match.sentence, policy: exclusionPolicy)
        )
    }

    static func mentionsNotAllocatableToSegments(_ text: String) -> Bool {
        BreakdownProseToolkit.mentionsNotAllocatableToSegments(text)
    }

    static func decide(
        plainText: String, code: String = "", docID: String = "",
        decider: any ResearchAndDevelopmentProseDeciding
    ) async -> ResearchAndDevelopmentProseDecision {
        await BreakdownProseToolkit.decideCompanyTotal(
            plainText: plainText, code: code, docID: docID,
            axis: breakdownAxisResearchAndDevelopment, preferredPhrases: preferredPhrases,
            policy: classifyPolicy, decider: decider)
    }

    static func snapshot(axis: String, total: ResearchAndDevelopmentProseTotal) -> BreakdownSnapshot
    {
        BreakdownSnapshot(
            axis: axis, denominator: total.yen,
            denominatorTag: breakdownDenominatorTagResearchAndDevelopmentProse,
            rows: [], sourceKind: breakdownSourceResearchAndDevelopmentProse,
            needsReview: false, warnings: total.warnings)
    }

    private static func additiveSum(_ snapshot: BreakdownSnapshot) -> Double {
        snapshot.rows
            .filter { BreakdownProseToolkit.isAdditiveRowKind($0.rowKind) }
            .map(\.amount)
            .reduce(0, +)
    }

    private static func matchesTaggedRow(_ yen: Double, snapshot: BreakdownSnapshot) -> Bool {
        matchesTaggedRow(
            yen,
            amounts: snapshot.rows.filter { BreakdownProseToolkit.isAdditiveRowKind($0.rowKind) }
                .map(\.amount))
    }

    private static func matchesTaggedRow(_ yen: Double, amounts: [Double]) -> Bool {
        BreakdownProseToolkit.matchesTaggedAmount(yen, amounts: amounts)
    }

    private static func snapshotByAddingAdjustment(
        _ snapshot: BreakdownSnapshot, yen: Double, label: String, warning: String
    ) -> BreakdownSnapshot {
        var filled = snapshot
        filled.rows.append(
            BreakdownRow(
                labelRaw: label, label: label, amount: yen,
                share: snapshot.denominator > 0 ? yen / snapshot.denominator : nil,
                profit: nil, rowKind: "reconciling"))
        let additive = additiveSum(filled)
        let adjusted = BreakdownProseToolkit.adjustedWarnings(
            existing: filled.warnings, farWarningNames: [segmentSumFarWarning],
            primaryFarWarning: segmentSumFarWarning,
            stillFar: BreakdownProseToolkit.stillFarFromTotal(
                denominator: filled.denominator, additive: additive),
            extraWarning: warning)
        filled.warnings = adjusted.warnings
        filled.needsReview = adjusted.needsReview
        return filled
    }
}

/// Decisions API へ研究開発費本文の Choice を出す。失敗時は selected = nil（行は作らない）。
struct OpenRouterResearchAndDevelopmentProseDecider: ResearchAndDevelopmentProseDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    static let remainderQuestion = "research_and_development_remainder"
    static let exclusionQuestion = "research_and_development_exclusion"

    func classify(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        await choice(
            question: ResearchAndDevelopmentProseTotalDecision.question,
            body: Self.requestJSON(model: model, sentence: sentence),
            sentence: sentence)
    }

    func classifyRemainder(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        await choice(
            question: Self.remainderQuestion,
            body: Self.remainderRequestJSON(model: model, sentence: sentence),
            sentence: sentence)
    }

    func classifyExclusion(sentence: String) async -> ResearchAndDevelopmentProseChoice {
        await choice(
            question: Self.exclusionQuestion,
            body: Self.exclusionRequestJSON(model: model, sentence: sentence),
            sentence: sentence)
    }

    private func choice(question: String, body: Data?, sentence: String)
        async -> ResearchAndDevelopmentProseChoice
    {
        await BreakdownProseOpenRouter.choice(
            client: client, question: question, body: body, sentence: sentence,
            retries: ResearchAndDevelopmentProseTotalDecision.classifyPolicy.transportRetries,
            onFailure: "ResearchAndDevelopmentProseTotal: Jev呼び出し失敗")
    }

    static func requestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            ResearchAndDevelopmentProseRole.currentCompanyTotal: """
                当期（当連結会計年度、当事業年度、当期）の会社全体の研究開発費の総額を述べている。 \
                セグメントに配分できないので総額のみ、という説明が同じ文にあっても、総額ならこれ。
                """,
            ResearchAndDevelopmentProseRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            ResearchAndDevelopmentProseRole.partialAmount: """
                一部のセグメント、疾患領域、地域、プロジェクトだけの金額である。会社全体の総額ではない。
                """,
            ResearchAndDevelopmentProseRole.unrelated: """
                研究開発費の総額ではない。従業員数、売上、設備投資、割合だけ、注記番号への参照を含む。
                """,
        ]
        return BreakdownProseOpenRouter.requestJSON(
            model: model, question: ResearchAndDevelopmentProseTotalDecision.question,
            sentence: sentence,
            instructions: "この文に出てくる金額は、当期の会社全体の研究開発費の総額か。文の意味で一つ選ぶ。金額の数値は選ばない。",
            criteria: criteria)
    }

    static func remainderRequestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            ResearchAndDevelopmentRemainderRole.unallocatedRemainder: """
                報告セグメントに配分されていない当期の研究開発費の残りを述べている。 \
                全社、共通、基礎研究、本社、各セグメントに帰属しない金額がこれにあたる。 \
                会社全体の研究開発費の総額そのものではない。
                """,
            ResearchAndDevelopmentRemainderRole.segmentAmount: """
                特定の報告セグメント、事業、地域、疾患領域だけの当期の金額である。
                """,
            ResearchAndDevelopmentRemainderRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            ResearchAndDevelopmentRemainderRole.unrelated: """
                研究開発費の残りではない。売上、従業員数、設備投資、割合だけ、注記番号への参照を含む。
                """,
        ]
        return BreakdownProseOpenRouter.requestJSON(
            model: model, question: remainderQuestion, sentence: sentence,
            instructions: "この文の金額は、報告セグメントに配分されていない当期の研究開発費の残りか。文の意味で一つ選ぶ。金額の数値は選ばない。",
            criteria: criteria)
    }

    static func exclusionRequestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            ResearchAndDevelopmentExclusionRole.excludedFromTotal: """
                文が述べる研究開発費の総額には含まれない、別の支出である。 \
                「このほか」と続く探鉱費のように、総額の外で支出した金額がこれにあたる。
                """,
            ResearchAndDevelopmentExclusionRole.includedInTotal: """
                その金額は、同じ文が述べる研究開発費の総額に含まれる。
                """,
            ResearchAndDevelopmentExclusionRole.priorPeriod: """
                前期、前連結会計年度、前事業年度の金額である。
                """,
            ResearchAndDevelopmentExclusionRole.unrelated: """
                研究開発費の総額の外の支出ではない。売上、従業員数、設備投資、割合だけを含む。
                """,
        ]
        return BreakdownProseOpenRouter.requestJSON(
            model: model, question: exclusionQuestion, sentence: sentence,
            instructions: "研究開発費の総額と一緒に出てくるもう一つの金額は、その総額の外の支出か。文の意味で一つ選ぶ。金額の数値は選ばない。",
            criteria: criteria)
    }
}
