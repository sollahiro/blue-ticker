// segment 解決（`SegmentBreakdownResolver`）が使う共有部品。product_service 軸は 2026-11 に廃止した。

import Foundation

/// どの経路で business breakdown を解決したか（監査・目視検証用）。
enum BusinessBreakdownSource: String {
    case xbrlFacts = "xbrl_facts"
    /// 積み上げセグメント損益表（売上→研究開発費→営業利益等）の決定論寄せ。
    case stackedSegmentPnL = "stacked_segment_pnl"
    case revenueRecognitionLLM = "revenue_recognition_llm"
    case segmentInfoLLM = "segment_info_llm"
    case notFound = "not_found"
}

enum BusinessBreakdownResolver {

    /// 空行の LLM スナップショットは `xbrl_facts` を隠すので採用しない（7273 S100YLTN）。
    static func hasUsableSegmentRows(_ snapshot: BreakdownSnapshot) -> Bool {
        snapshot.rows.contains { $0.rowKind == "segment" }
    }
}
