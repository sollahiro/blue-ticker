// `segments` キーの事業別内訳（business breakdown）を解決する。
// docs/segment-normalization-concept.md 参照。`SegmentExtractor.extractSegmentInfo` は
// 既にオークマ型（axis が geography 判定される場合）を収益認識関係注記へ axis-aware に
// swap 済みで返す（`isGeographyAxis` 判定＋`extractRevenueRecognitionInfo` フォールバック）。
// 本リゾルバはその後段として、method に応じてどの正規化器（xbrl_facts の決定的経路 /
// 2種類の LLM 正規化器）に振り分けるかだけを判断する。
//
// swap 済みの html_table は見出しが `SegmentExtractor.revenueRecognitionHeading`
// （`extractRevenueRecognitionInfo` の dedicatedHeading）で判別できる（swap はその
// SegmentResult をそのまま返すため）。それ以外の html_table（例: キヤノンの US-GAAP 注23）は
// `SegmentInfoLLMNormalizer` に回す。見出し文字列は `SegmentExtractor` 側の単一の真実源を
// 参照する（同じリテラルをここで再定義すると、抽出側の改名に気づかず追従漏れする恐れがある）。

import Foundation

/// どの経路で business breakdown を解決したか（監査・目視検証用）。
enum SegmentBusinessBreakdownSource: String {
    case xbrlFacts = "xbrl_facts"
    case revenueRecognitionLLM = "revenue_recognition_llm"
    case segmentInfoLLM = "segment_info_llm"
    case notFound = "not_found"
}

enum SegmentBusinessBreakdownResolver {

    /// segments（事業別セグメント情報。swap 済みの可能性あり）の SegmentResult から
    /// business 軸の BreakdownSnapshot を解決する。LLM 呼び出しは html_table 経路でのみ発生し、
    /// xbrl_facts で business 判定できた場合は呼び出さない（決定的経路を優先し LLM 費用を最小化）。
    static func resolve(
        segments: SegmentResult, consolidatedSales: Double?, client: ChatCompleting
    ) async -> (snapshot: BreakdownSnapshot?, source: SegmentBusinessBreakdownSource, audit: LLMBreakdownAudit?) {
        // 1) xbrl_facts 経路（決定的、LLM不要）。axis が geography のままなのは swap 対象の
        //    収益認識関係注記が見つからなかったケース（`SegmentExtractor` 側のフォールバック）
        //    なので、business としては採用しない。
        if let snapshot = SegmentNormalizer.normalize(segments, consolidatedSales: consolidatedSales) {
            guard snapshot.axis == "business" else { return (nil, .notFound, nil) }
            return (snapshot, .xbrlFacts, nil)
        }

        // 2) html_table 経路。見出しで「収益認識関係由来（swap 済み）」か
        //    「segments 自体が html_table（例: キヤノン注23）」かを振り分ける。
        // `method == "xbrl_facts"` でも tables が非空なら試す（facts 優先で method が
        // xbrl_facts になった会社が、facts の正規化失敗時に表スクレイピングへ
        // フォールバックできるようにするため。issue調査 2026-07-21、Grok 4.5 レビュー指摘）。
        guard !segments.tables.isEmpty else { return (nil, .notFound, nil) }

        if segments.tables.first?.heading == SegmentExtractor.revenueRecognitionHeading {
            let (snapshot, audit) = await RevenueRecognitionLLMNormalizer.normalize(
                segments, consolidatedSales: consolidatedSales, client: client
            )
            guard let snapshot else { return (nil, .notFound, audit) }
            return (snapshot, .revenueRecognitionLLM, audit)
        }

        let (snapshot, audit) = await SegmentInfoLLMNormalizer.normalize(
            segments, consolidatedSales: consolidatedSales, client: client
        )
        guard let snapshot else { return (nil, .notFound, audit) }
        return (snapshot, .segmentInfoLLM, audit)
    }
}
