// `segments` キーの事業別内訳（business breakdown）を解決する。
// docs/segment-normalization-concept.md「今後の検討事項3」で決定済みの
// オークマ型（segments キーの axis が geography 判定になるケース）配線方針をそのまま実装する:
//
//   (a) segments 結果の axis が geography なら、その snapshot を business としては採用しない
//       （geography-labeled snapshot をそのまま business として出さない）
//   (b) 可能なら収益認識注記（`SegmentExtractor.extractRevenueRecognitionInfo`）から
//       business breakdown を LLM で再抽出する
//   (c) 地域別（geography）は常に geography キー由来を正とする — 本リゾルバはそちらに触れない
//       （呼び出し側が `geography` キーの SegmentResult を別途正規化する。変更なし）
//
// `SegmentNormalizer.normalize()` 自体の挙動（axis をデータから判定して返す。学び10・
// `okumaSegmentsAxisIsGeography` テストで固定済みの仕様）は変更しない。採用可否の判断は
// このリゾルバ（呼び出し側）の責務とする。

import Foundation

/// どの経路で business breakdown を解決したか（監査・目視検証用）。
enum SegmentBusinessBreakdownSource: String {
    case xbrlFacts = "xbrl_facts"
    case htmlTableLLM = "html_table_llm"
    case revenueRecognitionLLM = "revenue_recognition_llm"
    case notFound = "not_found"
}

enum SegmentBusinessBreakdownResolver {

    /// segments（事業別セグメント情報）の SegmentResult と、あれば収益認識注記の SegmentResult から
    /// business 軸の BreakdownSnapshot を解決する。LLM 呼び出しは html_table 経路（Canon型のUS-GAAP注記・
    /// オークマ型の収益認識フォールバック）でのみ発生し、xbrl_facts で business 判定できた場合は
    /// 呼び出さない（決定的経路を優先し、LLM 費用を最小化する）。
    static func resolve(
        segments: SegmentResult,
        revenueRecognition: SegmentResult?,
        consolidatedSales: Double?,
        client: ChatCompleting
    ) async -> (snapshot: BreakdownSnapshot?, source: SegmentBusinessBreakdownSource, audit: LLMBreakdownAudit?) {
        // 1) xbrl_facts 経路（決定的、LLM不要）。
        if let snapshot = SegmentNormalizer.normalize(segments, consolidatedSales: consolidatedSales) {
            if snapshot.axis == "business" {
                return (snapshot, .xbrlFacts, nil)
            }
            // axis == "geography"（オークマ型）: (a) segments 結果は business として採用しない。
            guard let revenueRecognition else { return (nil, .notFound, nil) }
            // (b) 収益認識注記から business breakdown を再抽出する。
            let (fallback, audit) = await SegmentBreakdownLLMNormalizer.normalize(
                revenueRecognition, axis: "business", consolidatedSales: consolidatedSales, client: client
            )
            guard let fallback else { return (nil, .notFound, audit) }
            return (fallback, .revenueRecognitionLLM, audit)
        }

        // 2) html_table 経路（US-GAAP 注記等に事業別セグメント表が内包されているケース。例: キヤノン注23）。
        guard segments.method == "html_table" else { return (nil, .notFound, nil) }
        let (snapshot, audit) = await SegmentBreakdownLLMNormalizer.normalize(
            segments, axis: "business", consolidatedSales: consolidatedSales, client: client
        )
        guard let snapshot else { return (nil, .notFound, audit) }
        return (snapshot, .htmlTableLLM, audit)
    }
}
