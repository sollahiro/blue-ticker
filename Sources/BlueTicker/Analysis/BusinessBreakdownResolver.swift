// `segments` キーの事業別内訳（business breakdown）を解決する。
// docs/breakdown-normalization-concept.md 参照。`BreakdownExtractor.extractSegmentInfo` は
// 既にオークマ型（axis が geography 判定される場合）を収益認識関係注記へ axis-aware に
// swap 済みで返す（`isGeographyAxis` 判定＋`extractRevenueRecognitionInfo` フォールバック）。
// 本リゾルバはその後段として、method に応じてどの正規化器（xbrl_facts の決定的経路 /
// 2種類の LLM 正規化器）に振り分けるかだけを判断する。
//
// swap 済みの html_table は見出しが `BreakdownExtractor.revenueRecognitionHeading`
// （`extractRevenueRecognitionInfo` の dedicatedHeading）で判別できる（swap はその
// ExtractedBreakdown をそのまま返すため）。それ以外の html_table（例: キヤノンの US-GAAP 注23）は
// `SegmentInfoLLMNormalizer` に回す。見出し文字列は `BreakdownExtractor` 側の単一の真実源を
// 参照する（同じリテラルをここで再定義すると、抽出側の改名に気づかず追従漏れする恐れがある）。

import Foundation

/// どの経路で business breakdown を解決したか（監査・目視検証用）。
enum BusinessBreakdownSource: String {
    case xbrlFacts = "xbrl_facts"
    case revenueRecognitionLLM = "revenue_recognition_llm"
    case segmentInfoLLM = "segment_info_llm"
    case notFound = "not_found"
}

enum BusinessBreakdownResolver {

    /// segments（事業別セグメント情報。swap 済みの可能性あり）の ExtractedBreakdown から
    /// business 軸の BreakdownSnapshot を解決する。LLM 呼び出しは html_table 経路でのみ発生し、
    /// xbrl_facts で business 判定できた場合は呼び出さない（決定的経路を優先し LLM 費用を最小化）。
    static func resolve(
        segments: ExtractedBreakdown, consolidatedSales: Double?, client: ChatCompleting,
        labelsByTag: [String: String] = [:]
    ) async -> (snapshot: BreakdownSnapshot?, source: BusinessBreakdownSource, audit: LLMBreakdownAudit?) {
        let factsSnapshot = BreakdownNormalizer.normalize(
            segments, consolidatedSales: consolidatedSales, labelsByTag: labelsByTag)

        // 1) xbrl_facts 経路（決定的、LLM不要）。axis が business かつ needs_review が
        //    立っていなければ確信度が高いのでそのまま採用する。
        //    geography のままなのは swap 対象の収益認識/IFRS売上収益注記が見つからなかった
        //    （または収益種類だけの分解で意図的に swap しなかった）ケース。business としては
        //    採用せず、下の tables 経路へフォールバックする（住友ファーマ: 製品別表が
        //    セグメント注記 tables 側に残っている。実データ検証 2026-07-24）。
        if let factsSnapshot, factsSnapshot.axis == "business", !factsSnapshot.needsReview {
            return (factsSnapshot, .xbrlFacts, nil)
        }

        // 2) html_table 経路。見出しで「収益認識関係由来（swap 済み）」か
        //    「segments 自体が html_table（例: キヤノン注23）」かを振り分ける。
        // `method == "xbrl_facts"` でも tables が非空なら試す（facts 優先で method が
        // xbrl_facts になった会社が、facts の正規化失敗時に表スクレイピングへ
        // フォールバックできるようにするため。issue調査 2026-07-21、Grok 4.5 レビュー指摘）。
        // axis=business だが needs_review（表取り違えの疑い）の場合も同じ tables 経路を試す
        // （エーザイ旧filings型: 地域別 facts が誤って business と確定していたが、
        // classifyAxis 修正で needs_review=true になった後も、実際には製品別の html_table が
        // 別途存在する。Opus監査 finding #2 フォローアップ、2026-07-25）。
        // LLM が resolve せず終わった場合でも、audit（`notApplicableReason` 等）は呼び出し元へ
        // 持ち帰る（issue #135: html_table経由でLLMが「地域別のみ」等と判定した理由を
        // `BreakdownExtractor.classifyNotApplicableReason` の分類に使うため）。
        var lastAudit: LLMBreakdownAudit?
        if !segments.tables.isEmpty {
            if segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading {
                let (snapshot, audit) = await RevenueRecognitionLLMNormalizer.normalize(
                    segments, consolidatedSales: consolidatedSales, client: client
                )
                lastAudit = audit
                // needs_review が立った swap 経路の結果は採用しない。オークマ型は候補表が
                // 単一で needs_review=false に安定するが、INPEX旧filings型（複数期の候補表が
                // 同じ見出し・紛らわしい period ラベルで並ぶ）は再実行のたびに結果が変わる
                // （source_table_index の誤選択・タイムアウト・not_found が非決定的に発生）。
                // 低確信度のまま business 軸として保存するより空のままにする方が安全
                // （実データ検証: S100QH2B を複数回再実行し結果が毎回変化することを確認、2026-07-25）。
                if let snapshot, !snapshot.needsReview { return (snapshot, .revenueRecognitionLLM, audit) }
            } else {
                let (snapshot, audit) = await SegmentInfoLLMNormalizer.normalize(
                    segments, consolidatedSales: consolidatedSales, client: client
                )
                lastAudit = audit
                if let snapshot { return (snapshot, .segmentInfoLLM, audit) }
            }
        }

        // 3) LLM 経路が無い・失敗した場合、xbrl_facts の axis=business スナップショットが
        //    あれば（needs_review=true でも）何もないよりはマシなのでフォールバックする
        //    （INPEX旧filings型: tables が無く LLM 経路自体を試せない会社の挙動を変えない）。
        if let factsSnapshot, factsSnapshot.axis == "business" {
            return (factsSnapshot, .xbrlFacts, nil)
        }

        return (nil, .notFound, lastAudit)
    }
}
