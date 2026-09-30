// セグメント注記（business / geography の省略）だけを Jev に判定させる。
// コードが候補の文と表を切り出す。Jev は Choice だけを返す。
// `OPENROUTER_DECISION_API_KEY` が無いときは呼ばない（今日の決定論のまま）。
// 研究開発費・設備投資・減損は対象外。公開 reason は既存の文字列だけを使う。

import Foundation

enum SegmentNoteAxis: Sendable {
    case business
    case geography
}

enum SegmentNoteAction: Equatable, Sendable {
    case unchanged
    case omitBusiness
    case omitGeography
    case keepTable(Int)
}

struct SegmentNoteTableCandidate: Equatable, Sendable {
    var index: Int
    var heading: String
    var period: String?
    var markdown: String
}

enum SegmentNoteTableSelection: Equatable, Sendable {
    case table(Int)
    case noneOfThese
    case unavailable
}

enum SegmentNoteOmission: Equatable, Sendable {
    case singleSegment
    case productOrServiceExternalSalesOver90
    case domesticExternalSalesOver90
    case none
    case unavailable

    var choiceKey: String? {
        switch self {
        case .singleSegment: return "single_segment"
        case .productOrServiceExternalSalesOver90: return "product_or_service_external_sales_over_90"
        case .domesticExternalSalesOver90: return "domestic_external_sales_over_90"
        case .none: return "none"
        case .unavailable: return nil
        }
    }

    static func fromChoiceKey(_ key: String) -> SegmentNoteOmission {
        switch key {
        case "single_segment": return .singleSegment
        case "product_or_service_external_sales_over_90": return .productOrServiceExternalSalesOver90
        case "domestic_external_sales_over_90": return .domesticExternalSalesOver90
        case "none": return .none
        default: return .unavailable
        }
    }
}

protocol SegmentNoteDeciding: Sendable {
    func selectBreakdownTable(
        tables: [SegmentNoteTableCandidate], sentences: [String]
    ) async -> SegmentNoteTableSelection

    func classifyOmission(sentence: String) async -> SegmentNoteOmission
}

enum SegmentNoteDecision {
    /// 表が分析すべき当期の内訳か。違い、かつ省略の種類が軸に合うときだけ今日の経路を変える。
    /// 決定論で既に business / geography が確定しているときは呼ばない前提で、
    /// `hasCleanDeterministicSnapshot` が true ならネットワークに行かない。
    static func decide(
        axis: SegmentNoteAxis,
        tables: [BreakdownTable],
        sentences: [String],
        hasCleanDeterministicSnapshot: Bool,
        decider: any SegmentNoteDeciding
    ) async -> SegmentNoteAction {
        guard !hasCleanDeterministicSnapshot, !tables.isEmpty, !sentences.isEmpty else {
            return .unchanged
        }
        let candidates = tables.enumerated().map { index, table in
            SegmentNoteTableCandidate(
                index: index, heading: table.heading, period: table.period, markdown: table.markdown)
        }
        let selection = await decider.selectBreakdownTable(tables: candidates, sentences: sentences)
        switch selection {
        case .unavailable:
            return .unchanged
        case .table(let index):
            guard tables.indices.contains(index) else { return .unchanged }
            return .keepTable(index)
        case .noneOfThese:
            var omissions: [SegmentNoteOmission] = []
            for sentence in sentences {
                let omission = await decider.classifyOmission(sentence: sentence)
                if omission != .unavailable { omissions.append(omission) }
            }
            return action(axis: axis, omissions: omissions)
        }
    }

    private static func action(axis: SegmentNoteAxis, omissions: [SegmentNoteOmission]) -> SegmentNoteAction {
        switch axis {
        case .business:
            let omitsBusiness = omissions.contains(.singleSegment)
                || omissions.contains(.productOrServiceExternalSalesOver90)
            return omitsBusiness ? .omitBusiness : .unchanged
        case .geography:
            return omissions.contains(.domesticExternalSalesOver90) ? .omitGeography : .unchanged
        }
    }
}

/// Decisions API へセグメント注記の Choice を出す。失敗時は `.unavailable`（今日の分類に戻す）。
struct OpenRouterSegmentNoteDecider: SegmentNoteDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    static let breakdownTableQuestion = "breakdown_table"
    static let omissionQuestion = "omission"
    static let noneOfThese = "none_of_these"
    private static let markdownLimit = 4_000

    func selectBreakdownTable(
        tables: [SegmentNoteTableCandidate], sentences: [String]
    ) async -> SegmentNoteTableSelection {
        guard let body = Self.tableRequestJSON(model: model, tables: tables, sentences: sentences) else {
            return .unavailable
        }
        do {
            let data = try await client.decide(requestJSON: body)
            return Self.tableSelection(from: data, tableCount: tables.count)
        } catch {
            return .unavailable
        }
    }

    func classifyOmission(sentence: String) async -> SegmentNoteOmission {
        guard let body = Self.omissionRequestJSON(model: model, sentence: sentence) else {
            return .unavailable
        }
        do {
            let data = try await client.decide(requestJSON: body)
            return Self.omission(from: data)
        } catch {
            return .unavailable
        }
    }

    static func tableRequestJSON(
        model: String, tables: [SegmentNoteTableCandidate], sentences: [String]
    ) -> Data? {
        var criteria: [String: String] = [
            noneOfThese: """
                どれも分析すべき当期のセグメント内訳ではない。関連情報の表（主要な顧客など）は \
                セグメント内訳ではない。当期の注記が記載を省略していて、残っているのが前期の表だけのときも、 \
                その前期表は分析しない。
                """,
        ]
        var tableState: [[String: String]] = []
        for table in tables {
            let period = table.period ?? "不明"
            criteria["\(table.index)"] = """
                表\(table.index)（期間: \(period)、見出し: \(table.heading)）が、分析すべき当期の \
                セグメント内訳である。報告セグメント別、地域別の外部売上、または製品・サービス別の当期の表が \
                これにあたる。単一セグメントの省略文が別にあっても、当期の内訳表ならこの表を選ぶ。
                """
            tableState.append([
                "index": "\(table.index)",
                "period": period,
                "heading": table.heading,
                "markdown": String(table.markdown.prefix(markdownLimit)),
            ])
        }
        let questions: [String: Any] = [
            breakdownTableQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "抽出された表のうち、分析すべき当期のセグメント内訳はどれか。無ければ none_of_these。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model,
            state: ["sentences": sentences, "tables": tableState],
            questions: questions)
    }

    static func omissionRequestJSON(model: String, sentence: String) -> Data? {
        let criteria: [String: String] = [
            "single_segment": """
                単一セグメントであるため、セグメント情報の記載を省略している。 \
                例: 当社グループは、コミュニケーション・プラットフォーム関連事業の単一セグメントであるため、記載を省略しております。
                """,
            "product_or_service_external_sales_over_90": """
                単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略している。
                """,
            "domestic_external_sales_over_90": """
                本邦の外部顧客への売上高が、連結損益計算書または連結損益及び包括利益計算書の売上高の90％を超えるため、記載を省略している。
                """,
            "none": """
                上のどれでもない。報告セグメントと同一のため、または同様の情報を開示しているための記載省略を含む。
                """,
        ]
        let questions: [String: Any] = [
            omissionQuestion: OpenRouterDecisionsCodec.choiceQuestion(
                instructions: "この文は、セグメント注記のどの記載省略か。文の意味で一つ選ぶ。",
                criteria: criteria),
        ]
        return OpenRouterDecisionsCodec.requestJSON(
            model: model,
            state: ["sentence": sentence],
            questions: questions)
    }

    static func tableSelection(from data: Data, tableCount: Int) -> SegmentNoteTableSelection {
        guard let selected = OpenRouterDecisionsCodec.answers(from: data)[breakdownTableQuestion]?.choice?.selected
        else { return .unavailable }
        if selected == noneOfThese { return .noneOfThese }
        guard let index = Int(selected), (0..<tableCount).contains(index) else { return .unavailable }
        return .table(index)
    }

    static func omission(from data: Data) -> SegmentNoteOmission {
        guard let selected = OpenRouterDecisionsCodec.answers(from: data)[omissionQuestion]?.choice?.selected
        else { return .unavailable }
        return SegmentNoteOmission.fromChoiceKey(selected)
    }
}
