// 設備投資等の概要（capex の Overview セル）: 表の一部の行に ix:nonFraction が付かず、
// dimension 付き fact だけを読む `BreakdownNormalizer.normalizeCapitalExpendituresOverview` で
// 行が落ちる会社（6752 パナソニックHD「その他・全社 276」億円。報告セグメント・報告セグメント計・
// 合計にはタグがある）の行を補う。
//
// 値は開示のセルそのまま。円への倍率は同じ列のタグ付きセル（fact 値 ÷ セルの表示値）から出し、
// すべて同じ倍率のときだけ使う（億円・百万円を固定しない）。未タグ行の和が
// 「合計（分母）− タグ付き segment / reconciling 行」にぴったり一致しなければ何も足さない（差額で埋めない）。
// 行の種別（reconciling / segment）は語で決めず Jev が分類する（3 回一致・0.9）。合計・小計と
// 判定された行が1つでもある・キーが無い・合意できないときは足さない（fail-closed）。

import Foundation

protocol CapexOverviewRowDeciding: Sendable {
    func classifyOverviewRow(
        table: CapexOverviewUntaggedRowFill.Table, row: CapexOverviewUntaggedRowFill.Row, docID: String
    ) async -> JevChoiceAggregate.Sample
}

enum CapexOverviewUntaggedRowFill {
    struct Row: Equatable, Sendable {
        var label: String
        /// 金額列のセルの表示値（単位は表の見出しどおり）。
        var display: Double
        /// 金額セルに Overview タグの ix:nonFraction が付いている。
        var tagged: Bool
    }

    struct Table: Equatable, Sendable {
        /// 金額列の見出し（「金額（億円）」など。無ければ空）。
        var amountHeader: String
        var rows: [Row]
        /// 円 ÷ 表示値。タグ付きセルの fact 値から出す。
        var yenPerDisplayUnit: Double
    }

    struct FillResult: Equatable, Sendable {
        var snapshot: BreakdownSnapshot
        var audit: SegmentNoteJevAuditPayload?
    }

    static let question = "capex_overview_row_role"
    static let axis = breakdownAxisCapex
    static let reconcilingKey = "reconciling"
    static let segmentKey = "segment"
    static let totalKey = "total_or_subtotal"
    static let optionKeys = [reconcilingKey, segmentKey, totalKey]
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify, question: question, noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)
    /// これより多い未タグ行は聞かない（表の読み違いとみなす）。
    static let maxCandidates = 3

    static func fill(
        snapshot: BreakdownSnapshot, facts: [BreakdownFact], xbrlDir: URL,
        decider: (any CapexOverviewRowDeciding)?, code: String = "", docID: String
    ) async -> FillResult {
        let unchanged = FillResult(snapshot: snapshot, audit: nil)
        guard let decider, Xbrl.capexOverviewTags.contains(snapshot.denominatorTag),
              residual(of: snapshot) > 0
        else { return unchanged }
        let tag = snapshot.denominatorTag
        let current = facts.filter {
            $0.tag == tag && BreakdownNormalizer.isCurrentPeriodContext($0.contextRef)
        }
        let anchorRefs = Set(
            current.filter { XBRLUtils.primaryBreakdownMember($0.dimensions) != nil }.map(\.contextRef))
        guard !anchorRefs.isEmpty else { return unchanged }
        var valuesByRef: [String: Double] = [:]
        for fact in current where valuesByRef[fact.contextRef] == nil {
            valuesByRef[fact.contextRef] = fact.value
        }
        let tables = IxbrlTableHTML.htmlFiles(in: xbrlDir, containing: tag).flatMap {
            parseTables(html: $0, tag: tag, valuesByRef: valuesByRef, anchorRefs: anchorRefs)
        }
        for table in tables {
            guard let rows = candidates(snapshot: snapshot, table: table) else { continue }
            return await classifyAndApply(
                snapshot: snapshot, table: table, rows: rows, decider: decider,
                code: code, docID: docID)
        }
        return unchanged
    }

    /// 純関数。未タグ行のうち、和が残差（分母 − segment / reconciling）にぴったり一致する組。
    /// 一致しない・候補が無い・多すぎるときは nil。
    static func candidates(snapshot: BreakdownSnapshot, table: Table) -> [Row]? {
        let gap = residual(of: snapshot)
        guard snapshot.denominator > 0, gap > 0, table.yenPerDisplayUnit > 0 else { return nil }
        let existing = Set(snapshot.rows.flatMap { [compact($0.labelRaw), compact($0.label ?? "")] })
        var seen: Set<String> = []
        var rows: [Row] = []
        for row in table.rows where !row.tagged && row.display > 0 {
            let key = compact(row.label)
            guard !key.isEmpty, !existing.contains(key), seen.insert(key).inserted else { continue }
            rows.append(row)
        }
        guard !rows.isEmpty, rows.count <= maxCandidates else { return nil }
        let sum = rows.reduce(0.0) { $0 + yen($1, in: table) }
        // 表示値 × 倍率は開示の丸め単位どおり。円の端数（浮動小数）だけを許す。
        guard abs(sum - gap) < 0.5 else { return nil }
        return rows
    }

    static func yen(_ row: Row, in table: Table) -> Double {
        (row.display * table.yenPerDisplayUnit).rounded()
    }

    /// 純関数。Jev が分類した行を足す。合計・小計が混じる・未分類が残るときは元のまま。
    static func apply(
        snapshot: BreakdownSnapshot, table: Table, rows: [Row], roles: [String: String]
    ) -> BreakdownSnapshot? {
        var filled = snapshot
        for row in rows {
            guard let role = roles[row.label], role == reconcilingKey || role == segmentKey
            else { return nil }
            let amount = yen(row, in: table)
            filled.rows.append(
                BreakdownRow(
                    labelRaw: row.label, label: row.label, amount: amount,
                    share: amount / snapshot.denominator, profit: nil, rowKind: role))
        }
        guard abs(residual(of: filled)) < 0.5 else { return nil }
        // 行の和が分母と一致したので、行不足による乖離警告は解消する。
        filled.warnings.removeAll { $0.hasSuffix("_segment_sum_far_from_total") }
        filled.needsReview = !filled.warnings.isEmpty
        return filled
    }

    private static func classifyAndApply(
        snapshot: BreakdownSnapshot, table: Table, rows: [Row],
        decider: any CapexOverviewRowDeciding, code: String, docID: String
    ) async -> FillResult {
        var roles: [String: String] = [:]
        var calls: [SegmentNoteJevCallPayload] = []
        var model = ""
        var sentences: [String] = []
        for row in rows {
            let result = await JevDecisionSampler.decide(policy: jevPolicy, options: optionKeys) {
                await decider.classifyOverviewRow(table: table, row: row, docID: docID)
            }
            calls += result.calls
            if model.isEmpty { model = result.aggregate.model }
            let role = result.selectedKey
            sentences.append(
                "capex_overview_row_jev=\(role ?? "fail_closed") row=\(row.label) display=\(row.display)")
            guard let role else { break }
            roles[row.label] = role
        }
        let filled = apply(snapshot: snapshot, table: table, rows: rows, roles: roles)
        let audit = SegmentNoteJevAuditPayload(
            code: code, docID: docID, axis: axis,
            model: model.isEmpty ? Api.openrouterDecisionsModel : model,
            threshold: jevPolicy.auditThreshold, applied: filled != nil, needsReview: false,
            sentences: sentences, calls: calls)
        return FillResult(snapshot: filled ?? snapshot, audit: audit)
    }

    private static func residual(of snapshot: BreakdownSnapshot) -> Double {
        let included = snapshot.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .reduce(0.0) { $0 + $1.amount }
        return snapshot.denominator - included
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "　" && $0 != "・" }
    }

    // MARK: - HTML

    /// 純関数。セグメント member 付きの当期 fact を持つ表を読む。金額列は当期のタグ付きセルが
    /// 並ぶ1列（行ごとに列位置が揃わない表は読まない）。倍率はタグ付きセルの fact 値 ÷ 表示値で、
    /// どのセルでも同じときだけ（揃わない表は読まない）。
    static func parseTables(
        html: String, tag: String, valuesByRef: [String: Double], anchorRefs: Set<String>
    ) -> [Table] {
        var out: [Table] = []
        for tableHTML in IxbrlTableHTML.tables(in: html, containing: tag) {
            let grid = IxbrlTableHTML.rows(in: tableHTML).map(IxbrlTableHTML.cellBodies(in:))
            var column: Int?
            var width: Int?
            var anchored = false
            var ratios: [Double] = []
            var consistent = true
            for cells in grid {
                for (index, cell) in cells.enumerated() {
                    let refs = IxbrlTableHTML.factContextRefs(in: cell, tag: tag)
                    guard let ref = refs.first(where: { valuesByRef[$0] != nil }), let value = valuesByRef[ref]
                    else { continue }
                    if anchorRefs.contains(ref) { anchored = true }
                    if column == nil { column = index }
                    if width == nil { width = cells.count }
                    guard column == index, width == cells.count,
                          let display = number(IxbrlTableHTML.plainText(cell)), display > 0
                    else { consistent = false; continue }
                    ratios.append(value / display)
                }
            }
            guard anchored, consistent, let column, let width, let ratio = ratios.first,
                  ratios.allSatisfy({ abs($0 - ratio) <= ratio * 1e-9 })
            else { continue }
            var rows: [Row] = []
            for cells in grid where cells.count == width {
                let label = IxbrlTableHTML.plainText(cells[0])
                guard !label.isEmpty, number(label) == nil,
                      let display = number(IxbrlTableHTML.plainText(cells[column]))
                else { continue }
                let tagged = !IxbrlTableHTML.factContextRefs(in: cells[column], tag: tag).isEmpty
                rows.append(Row(label: label, display: display, tagged: tagged))
            }
            let header = grid.first(where: { $0.count == width }).map {
                IxbrlTableHTML.plainText($0[column])
            } ?? ""
            out.append(Table(amountHeader: header, rows: rows, yenPerDisplayUnit: ratio))
        }
        return out
    }

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"^[0-9][0-9,]*(?:\.[0-9]+)?$"#)

    /// セル全体が非負の数値（カンマ・小数可）のときだけ読む。注記記号・△・空欄は読まない。
    private static func number(_ text: String) -> Double? {
        let ns = NSRange(text.startIndex..., in: text)
        guard numberPattern.firstMatch(in: text, range: ns) != nil else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: ""))
    }
}

struct OpenRouterCapexOverviewRowDecider: CapexOverviewRowDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func classifyOverviewRow(
        table: CapexOverviewUntaggedRowFill.Table, row: CapexOverviewUntaggedRowFill.Row, docID: String
    ) async -> JevChoiceAggregate.Sample {
        let options = CapexOverviewUntaggedRowFill.optionKeys
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        guard let body = Self.requestJSON(model: model, table: table, row: row, docID: docID)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: CapexOverviewUntaggedRowFill.jevPolicy.transportRetries,
            onFailure: "CapexOverviewUntaggedRowFill: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[
            CapexOverviewUntaggedRowFill.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }

    static func requestJSON(
        model: String, table: CapexOverviewUntaggedRowFill.Table,
        row: CapexOverviewUntaggedRowFill.Row, docID: String
    ) -> Data? {
        let candidates = [
            JevPresentedCandidate(
                key: CapexOverviewUntaggedRowFill.reconcilingKey,
                criterion: """
                    The target row is not a single reportable segment: it is a bucket that reconciles \
                    the reportable segments to the consolidated total, such as other businesses and \
                    corporate (その他・全社, その他及び全社), corporate / head office (全社, 本社), \
                    unallocated amounts, adjustments or eliminations (調整額, 消去).
                    """),
            JevPresentedCandidate(
                key: CapexOverviewUntaggedRowFill.segmentKey,
                criterion: "The target row is one reportable business segment of the company."),
            JevPresentedCandidate(
                key: CapexOverviewUntaggedRowFill.totalKey,
                criterion: """
                    The target row is a total or subtotal of other rows (合計, 報告セグメント計, 小計), \
                    or not an amount row of this table.
                    """),
        ]
        let state: [String: Any] = [
            "doc_id": docID,
            "amount_column_header": table.amountHeader,
            "rows": table.rows.map { ["label": $0.label, "amount": $0.display, "xbrl_tagged": $0.tagged] },
            "target_row": row.label,
        ]
        let instructions = """
            The state is the capital expenditure overview table (設備投資等の概要) of a Japanese annual \
            securities report (有価証券報告書, doc \(docID)). Rows marked xbrl_tagged are tagged per \
            reportable segment, reportable-segment subtotal and consolidated total; the target row \
            has no XBRL tag. Classify the target row.
            """
        return JevDecisionRequest.json(
            model: model, question: CapexOverviewUntaggedRowFill.question,
            instructions: instructions, candidates: candidates, state: state)
    }
}
