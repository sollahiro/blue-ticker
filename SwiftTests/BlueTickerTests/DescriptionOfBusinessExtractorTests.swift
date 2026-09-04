// 「事業の内容」抽出。Filing texts キーは増やさない。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct DescriptionOfBusinessExtractorTests {
    private let ixFixture = """
        <div>
        <ix:nonNumeric contextRef="FilingDateInstant" name="jpcrp_cor:DescriptionOfBusinessTextBlock" escape="true">
        <h3>３ 【事業の内容】</h3>
        <p>当社は自動車の設計、製造および販売を行っています。</p>
        </ix:nonNumeric>
        <h3>４ 【関係会社の状況】</h3>
        <p>子会社の一覧。</p>
        </div>
        """

    private let escapedFixture = """
        <div>
        <ix:nonNumeric contextRef="FilingDateInstant" name="jpcrp_cor:DescriptionOfBusinessTextBlock" escape="true">
        &lt;h3&gt;３ 【事業の内容】&lt;/h3&gt;&lt;p&gt;当社は自動車の設計、製造および販売を行っています。&lt;/p&gt;
        </ix:nonNumeric>
        </div>
        """

    @Test func extractsIxBlockAndDoesNotLeakNextSection() {
        let text = DescriptionOfBusinessExtractor.extract(html: ixFixture)
        #expect(text.contains("自動車の設計、製造および販売"))
        #expect(!text.contains("子会社の一覧"))
    }

    @Test func extractsEntityEscapedInnerHtml() {
        let text = DescriptionOfBusinessExtractor.extract(html: escapedFixture)
        #expect(text.contains("自動車の設計、製造および販売"))
    }

    @Test func headingFallbackStopsAtNextSection() {
        let html = """
            <h3>３ 【事業の内容】</h3>
            <p>冷凍食品の製造販売を行う。</p>
            <h3>４ 【関係会社の状況】</h3>
            <p>子会社の一覧。</p>
            """
        let text = DescriptionOfBusinessExtractor.extract(html: html)
        #expect(text.contains("冷凍食品の製造販売"))
        #expect(!text.contains("子会社の一覧"))
    }

    @Test func extractsFromXbrlDirHtmlThenXml() throws {
        let dir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("0102010_honbun_ixbrl.htm")
        try ixFixture.write(to: html, atomically: true, encoding: .utf8)
        #expect(DescriptionOfBusinessExtractor.extract(in: dir).contains("自動車の設計"))

        let xmlOnly = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: xmlOnly) }
        let xbrl = xmlOnly.appendingPathComponent("instance.xbrl")
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xbrl xmlns:jpcrp_cor="http://disclosure.edinet-fsa.go.jp/taxonomy/jpcrp">
            <jpcrp_cor:DescriptionOfBusinessTextBlock contextRef="FilingDateInstant">\
            &lt;p&gt;当社は調味料の製造販売を行う。&lt;/p&gt;\
            </jpcrp_cor:DescriptionOfBusinessTextBlock>
            </xbrl>
            """
        try xml.write(to: xbrl, atomically: true, encoding: .utf8)
        #expect(DescriptionOfBusinessExtractor.extract(in: xmlOnly).contains("調味料の製造販売"))
    }
}
