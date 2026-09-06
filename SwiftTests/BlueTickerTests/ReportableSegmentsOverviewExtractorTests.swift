// 「報告セグメントの概要」抽出。Filing texts キーは増やさない。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct ReportableSegmentsOverviewExtractorTests {
    private let ixFixture = """
        <div>
        <ix:nonNumeric contextRef="CurrentYearDuration" name="jpcrp_cor:DescriptionOfReportableSegmentsTextBlock" escape="true">
        <p>１．報告セグメントの概要</p>
        <p>当社グループは、「トイホビー事業」「デジタル事業」を報告セグメントとしている。</p>
        </ix:nonNumeric>
        <h3>【関連情報】</h3>
        <p>外部顧客への売上高。</p>
        </div>
        """

    @Test func extractsDedicatedTagAndStopsBeforeRelatedInfo() {
        let text = ReportableSegmentsOverviewExtractor.extract(html: ixFixture)
        #expect(text.contains("トイホビー事業"))
        #expect(text.contains("デジタル事業"))
        #expect(!text.contains("外部顧客への売上高"))
    }

    @Test func headingFallbackStopsAtRelatedInfo() {
        let html = """
            <ix:nonNumeric name="jpigp_cor:NotesSegmentInformationConsolidatedFinancialStatementsIFRSTextBlock">
            <p>報告セグメントの概要</p>
            <p>半導体・電子材料、モビリティ、ケミカルの３つを報告セグメントとしている。</p>
            <p>【関連情報】</p>
            <p>地域別の外部顧客。</p>
            </ix:nonNumeric>
            """
        let text = ReportableSegmentsOverviewExtractor.extract(html: html)
        #expect(text.contains("半導体・電子材料"))
        #expect(text.contains("モビリティ"))
        #expect(!text.contains("地域別の外部顧客"))
    }

    @Test func concatenatesPagedDedicatedBlocks() {
        let html = """
            <ix:nonNumeric name="jpcrp_cor:DescriptionOfReportableSegmentsTextBlock">一段目のトイホビー。</ix:nonNumeric>
            <ix:nonNumeric name="jpcrp_cor:DescriptionOfReportableSegmentsTextBlock">二段目のデジタル。</ix:nonNumeric>
            """
        let text = ReportableSegmentsOverviewExtractor.extract(html: html)
        #expect(text.contains("トイホビー"))
        #expect(text.contains("デジタル"))
    }
}
