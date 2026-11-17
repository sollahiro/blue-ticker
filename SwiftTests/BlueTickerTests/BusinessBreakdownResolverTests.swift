// BusinessBreakdownResolver のユニットテスト。
// `BreakdownExtractor.extractSegmentInfo` の axis-aware swap（オークマ型は既に収益認識注記へ
// swap 済みで返る）を前提に、以降の振り分け（xbrl_facts / revenue_recognition_llm /
// segment_info_llm）を実データ golden + モック LLM で検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct BusinessBreakdownResolverTests {

    private static func loadGolden() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/breakdown_extraction_expected.json")
        let data = try Data(contentsOf: path)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    private static func loadSales(code: String) throws -> Double? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("smoke/smoke_expected")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let matches = files.filter { $0.hasPrefix("\(code)_") }.sorted()
        for file in matches {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let income = json?["income_statement"] as? [String: Any]
            if let sales = (income?["sales"] as? NSNumber)?.doubleValue { return sales }
        }
        return nil
    }

    private static func extracted(docID: String, key: String = "segments") throws -> ExtractedBreakdown {
        let golden = try loadGolden()
        let entry = try #require(golden[docID])
        let dict = try #require(entry[key] as? [String: Any])
        return ExtractedBreakdown(dictionary: dict)
    }

    private static func segmentsResult(docID: String) throws -> ExtractedBreakdown {
        try extracted(docID: docID, key: "segments")
    }

    /// 報告セグメント facts は product_service に載せない（軸は segment）。

    /// オークマ最新 S100YFQC: 収益認識の品目表が前期（table 0, 206,822）と当期
    /// （table 1, 235,888）に分かれ、行は NC旋盤 / マシニングセンタ 等 5 つ＋構成比。
    /// 地理行は無い。当期表を選んで公開する。

    /// 列選択の confidence が閾値未満でも snapshot は採用する（needs_review）。
    /// 捨てると単一セグメント開示（F）へ落ち、東京エレクトロン型の製品別が取れない。

    /// 回帰テスト（issue調査 2026-07-21）: `method == "xbrl_facts"` でも
    /// facts の正規化に失敗する（未知タグで売上高・銀行・保険いずれの経路にも一致しない）場合、
    /// tables が非空なら LLM の表フォールバックへ回る（facts 優先化で tables を破棄していた頃は
    /// ここで永久に notFound になっていた）。

    /// 富士フイルム（積み上げセグメント損益表）: 決定論寄せで解決し、LLM を呼ばない。
    /// 研究開発費ブロックを profit に誤寄せしないこと（S100W3XJ / S100YIBH 同型）。

    /// キヤノン（segments が html_table。US-GAAP 注23、見出しが「セグメント情報」で振り分けて
    /// SegmentInfoLLMNormalizer 経由で解決する）。

    /// swap 対象の収益認識関係注記が見つからず `BreakdownExtractor` 側のフォールバックで
    /// 元の地域別 xbrl_facts がそのまま返ってきたケース（tables も空）。
    /// axis が geography のままの xbrl_facts は business としては採用せず not_found にする。
    /// 合成 fact（実データ golden には該当書類が無いため）で決定的に検証する。

    /// 住友ファーマ型: 報告セグメント facts は geography だが、セグメント注記 tables に製品別表が残る。
    /// geography snapshot を短絡 discard せず、SegmentInfoLLM へフォールバックする。

    /// 地域別のみのセグメント情報表は business に載せない。audit の geography_only を持ち帰る。

    /// Jev が none_of_these のとき snapshot は無く、列選択の audit は持ち帰る。

    /// 列選択が needs_review でも採用する。not_applicable_reason は無い。

    /// segments が not_found の場合は何も呼ばない。

    /// 収益認識の行が報告セグメントと同じ内訳・同じ開示金額なら、LLM 無しでも
    /// geography facts を product_service に載せ、利益と調整行を残す。

    /// 収益認識の行が酒類・飲料なら、同じ売上合計でも facts に切り替えない。

    private static let japanEuropeLabels: [String: String] = [
        "JapanEastAsiaReportableSegmentMember": "日本・東アジア",
        "EuropeReportableSegmentMember": "欧州",
        "ReconcilingItemsMember": "調整額",
        "ReportableSegmentsMember": "計",
        Xbrl.entityTotalMemberName: "連結",
    ]

    private static func matchingRegionRevenueTable() -> BreakdownTable {
        BreakdownTable(
            heading: BreakdownExtractor.revenueRecognitionHeading,
            markdown: """
            | 区分 | 酒類 | 合計 |
            | 日本・東アジア | 800 | 1,234 |
            | 欧州 | 1,200 | 2,000 |
            | 合計 | 2,000 | 3,234 |
            """,
            period: "当期",
            unitCaption: "百万円"
        )
    }

    private static func japanEuropeFacts(japanSales: Double, europeSales: Double) -> [BreakdownFact] {
        let yen = Financial.millionYen
        func fact(
            tag: String, member: String?, value: Double
        ) -> BreakdownFact {
            var dimensions: [String: String] = [:]
            if let member {
                dimensions["OperatingSegmentsAxis"] = member
            }
            let ctx = member.map { "CurrentYearDuration_\($0)" } ?? "CurrentYearDuration"
            return BreakdownFact(
                tag: tag, contextRef: ctx, dimensions: dimensions, value: value,
                label: nil, unitRef: "JPY", decimals: "-6")
        }
        return [
            fact(tag: "SalesToExternalCustomersIFRS", member: "JapanEastAsiaReportableSegmentMember", value: japanSales),
            fact(tag: "SalesToExternalCustomersIFRS", member: "EuropeReportableSegmentMember", value: europeSales),
            fact(tag: "SalesToExternalCustomersIFRS", member: "ReportableSegmentsMember", value: japanSales + europeSales),
            fact(tag: "SalesToExternalCustomersIFRS", member: "ReconcilingItemsMember", value: -100 * yen),
            fact(tag: "SalesToExternalCustomersIFRS", member: nil, value: japanSales + europeSales - 100 * yen),
            fact(tag: "OperatingProfitLossIFRS", member: "JapanEastAsiaReportableSegmentMember", value: 62_584 * yen),
            fact(tag: "OperatingProfitLossIFRS", member: "EuropeReportableSegmentMember", value: 79_386 * yen),
            fact(tag: "OperatingProfitLossIFRS", member: "ReportableSegmentsMember", value: 209_463 * yen),
            fact(tag: "OperatingProfitLossIFRS", member: "ReconcilingItemsMember", value: -23_592 * yen),
            fact(tag: "OperatingProfitLossIFRS", member: nil, value: 185_870 * yen),
        ]
    }
}
