import Testing
import Foundation
@testable import BlueTickerCore

// XBRLParser（Analysis/XBRLSectionParser.swift）のセクション抽出仕様。
// 有報セクション本文は 有報セクション取り込み で Neon に格納され、抽出ロジックの変更は
// filingSectionsCacheVersion のバンプ判断に直結する（`.agents/rules/versioning.md`）。ここでは合成
// フィクスチャで HTML 経由（extractSection / extractSections）・TextBlock 経由
// （extractSectionsByType）・報告書種別判定（detectReportType）の挙動を固定する。

@Suite struct XBRLSectionParserTests {

    private func withDir(_ body: (URL) throws -> Void) throws {
        let dir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func write(_ content: String, as name: String, in dir: URL) throws {
        try content.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - HTML 経由: extractSection

    private let riskHtml = """
        <html><body>
        <h3>第2【事業等のリスク】</h3>
        <p>当社グループの経営成績に重要な影響を与える可能性のあるリスクは以下のとおりです。</p>
        <p>為替変動リスク。</p>
        <h3>第3【経営上の重要な契約等】</h3>
        <p>該当事項はありません。</p>
        </body></html>
        """

    @Test func extractSectionReturnsBodyUntilNextHeading() throws {
        try withDir { dir in
            try write(riskHtml, as: "0101010_honbun_test.htm", in: dir)
            let text = XBRLParser().extractSection(in: dir, sectionName: "事業等のリスク")
            #expect(text?.contains("為替変動リスク") == true)
            // 次の見出し以降（別セクション）は含めない
            #expect(text?.contains("該当事項はありません") == false)
        }
    }

    @Test func extractSectionPattern2PicksInnermostDivNotWrapper() throws {
        // 外側 div がタイトルを含む場合、文書全体ではなく内側要素を返す
        let html = """
            <html><body>
            <div id="wrapper">
              <div><p>目次や前文テキスト</p></div>
              <div>
                <p>【事業等のリスク】</p>
                <p>為替変動リスクの詳細説明。</p>
              </div>
              <div><p>別セクションの内容</p></div>
            </div>
            </body></html>
            """
        try withDir { dir in
            try write(html, as: "0101010_honbun_test.htm", in: dir)
            let text = XBRLParser().extractSection(in: dir, sectionName: "事業等のリスク")
            #expect(text?.contains("為替変動リスクの詳細説明") == true)
            #expect(text?.contains("目次や前文テキスト") == false)
            #expect(text?.contains("別セクションの内容") == false)
        }
    }

    @Test func extractSectionReturnsNilWhenSectionMissing() throws {
        try withDir { dir in
            try write(riskHtml, as: "0101010_honbun_test.htm", in: dir)
            #expect(XBRLParser().extractSection(in: dir, sectionName: "研究開発活動") == nil)
        }
    }

    @Test func extractSectionCapsTextAtTenThousandChars() throws {
        // cleanText は 10,000 文字で切り詰めて "..." を付ける（有報セクション取り込み 格納サイズの上限）
        let long = String(repeating: "あ", count: 12_000)
        let html = "<html><body><h3>【事業等のリスク】</h3><p>\(long)</p><h3>次の見出し</h3></body></html>"
        try withDir { dir in
            try write(html, as: "0101010_honbun_test.htm", in: dir)
            let text = XBRLParser().extractSection(in: dir, sectionName: "事業等のリスク")
            #expect(text?.count == 10_003)
            #expect(text?.hasSuffix("...") == true)
        }
    }

    // MARK: - HTML 経由: extractSections（1回パースの複数セクション抽出）

    @Test func extractSectionsResolvesMultipleKeysFromOneFile() throws {
        let html = """
            <html><body>
            <h3>【事業等のリスク】</h3>
            <p>為替変動リスク。</p>
            <h3>【研究開発活動】</h3>
            <p>新素材の研究を継続しています。</p>
            </body></html>
            """
        try withDir { dir in
            try write(html, as: "0101010_honbun_test.htm", in: dir)
            let result = XBRLParser().extractSections(in: dir, titlesByKey: [
                "business_risks": "事業等のリスク",
                "research_and_development": "研究開発活動",
                "mda": "経営者による財政状態、経営成績及びキャッシュ・フローの状況の分析",
            ])
            #expect(result["business_risks"]?.contains("為替変動リスク") == true)
            #expect(result["research_and_development"]?.contains("新素材の研究") == true)
            // 見つからないセクションはキーごと返さない
            #expect(result["mda"] == nil)
        }
    }

    @Test func extractSectionsScansOnlyHonbunFilesWhenPresent() throws {
        // honbun / ixbrl を含むファイルがあるとき、それ以外の HTML は走査しない
        try withDir { dir in
            try write(riskHtml, as: "extra.html", in: dir)
            try write("<html><body><p>目次のみ</p></body></html>",
                      as: "0000000_honbun_test.htm", in: dir)
            let result = XBRLParser().extractSections(
                in: dir, titlesByKey: ["business_risks": "事業等のリスク"])
            #expect(result.isEmpty)
        }
    }

    // MARK: - TextBlock 経由: extractSectionsByType

    private func instanceXml(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbrli:xbrl
            xmlns:xbrli="http://www.xbrl.org/2003/instance"
            xmlns:jpcrp_cor="http://disclosure.edinet-fsa.go.jp/taxonomy/jpcrp/2022-11-01/jpcrp_cor">
        \(body)
        </xbrli:xbrl>
        """
    }

    private let riskBody =
        "【事業等のリスク】当社グループの事業運営には様々なリスクが存在し、"
        + "経営成績および財政状態に重要な影響を及ぼす可能性があります。"

    @Test func extractSectionsByTypeMatchesTextBlockElementName() throws {
        let xml = instanceXml(
            "<jpcrp_cor:BusinessRisksTextBlock contextRef=\"C\">"
            + "&lt;p&gt;\(riskBody)&lt;/p&gt;"
            + "</jpcrp_cor:BusinessRisksTextBlock>")
        try withDir { dir in
            try write(xml, as: "jpcrp040300-asr-001_test.xbrl", in: dir)
            let result = XBRLParser().extractSectionsByType(in: dir)
            // ensureStartsWithTitle が【】を外し、タイトルを先頭化する
            #expect(result["business_risks"]?.hasPrefix("事業等のリスク") == true)
            #expect(result["business_risks"]?.contains("様々なリスク") == true)
            #expect(result["business_risks"]?.contains("【") == false)
            // 年次報告書は未検出セクションを空文字で埋める
            #expect(result["mda"] == "")
        }
    }

    @Test func extractSectionsByTypeFallsBackToTitleMatch() throws {
        // xbrlElements に無い要素名でも、本文冒頭のタイトルでセクションを特定する
        let rdBody =
            "【研究開発活動】当社グループは新素材および製造プロセスの研究開発を継続的に実施しており、"
            + "当連結会計年度の研究開発費の総額は百万円単位で開示しています。"
        let xml = instanceXml(
            "<jpcrp_cor:CompanySpecificNoteTextBlock contextRef=\"C\">"
            + "&lt;p&gt;\(rdBody)&lt;/p&gt;"
            + "</jpcrp_cor:CompanySpecificNoteTextBlock>")
        try withDir { dir in
            try write(xml, as: "jpcrp040300-asr-001_test.xbrl", in: dir)
            let result = XBRLParser().extractSectionsByType(in: dir)
            #expect(result["research_and_development"]?.contains("新素材") == true)
        }
    }

    @Test func textWithoutTitleGetsTitlePrepended() throws {
        // TextBlock 本文にタイトルが無い場合、タイトルを先頭に付与して返す
        let body =
            "当社グループの事業運営には様々な不確実性が存在し、"
            + "経営成績および財政状態に重要な影響を及ぼす可能性があります。"
        let xml = instanceXml(
            "<jpcrp_cor:BusinessRisksTextBlock contextRef=\"C\">"
            + "&lt;p&gt;\(body)&lt;/p&gt;"
            + "</jpcrp_cor:BusinessRisksTextBlock>")
        try withDir { dir in
            try write(xml, as: "jpcrp040300-asr-001_test.xbrl", in: dir)
            let result = XBRLParser().extractSectionsByType(in: dir)
            #expect(result["business_risks"]?.hasPrefix("事業等のリスク ") == true)
        }
    }

    @Test func interimReportDoesNotFillMissingSectionsWithEmpty() throws {
        let xml = instanceXml(
            "<jpcrp_cor:BusinessRisksTextBlock contextRef=\"C\">"
            + "&lt;p&gt;\(riskBody)&lt;/p&gt;"
            + "</jpcrp_cor:BusinessRisksTextBlock>")
        try withDir { dir in
            try write(xml, as: "jpcrp030300-q2r-001_test.xbrl", in: dir)
            let result = XBRLParser().extractSectionsByType(in: dir)
            #expect(result["business_risks"]?.contains("様々なリスク") == true)
            // 半期報告書は未検出セクションを空文字で埋めない（キーごと省略）
            #expect(result["mda"] == nil)
        }
    }

    @Test func shortTextBlocksAreIgnored() throws {
        // 50 文字以下の TextBlock はノイズとして無視する
        let xml = instanceXml(
            "<jpcrp_cor:BusinessRisksTextBlock contextRef=\"C\">短文</jpcrp_cor:BusinessRisksTextBlock>")
        try withDir { dir in
            try write(xml, as: "jpcrp040300-asr-001_test.xbrl", in: dir)
            let result = XBRLParser().extractSectionsByType(in: dir)
            // 未検出扱い → annual は空文字で埋める
            #expect(result["business_risks"] == "")
        }
    }

    // MARK: - detectReportType

    @Test func detectsAnnualFromFileName() throws {
        try withDir { dir in
            try write(instanceXml(""), as: "jpcrp040300-asr-001_test.xbrl", in: dir)
            #expect(XBRLParser().detectReportType(in: dir) == "annual")
        }
    }

    @Test func detectsInterimFromFileName() throws {
        try withDir { dir in
            try write(instanceXml(""), as: "jpcrp030300-q2r-001_test.xbrl", in: dir)
            #expect(XBRLParser().detectReportType(in: dir) == "interim")
        }
    }

    @Test func detectsInterimFromDocumentTypeElement() throws {
        // ファイル名から判定できないときは XML 内の DocumentType 要素で判定する
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xbrli:xbrl
                xmlns:xbrli="http://www.xbrl.org/2003/instance"
                xmlns:jpdei_cor="http://disclosure.edinet-fsa.go.jp/taxonomy/jpdei/2013-08-31/jpdei_cor">
              <jpdei_cor:DocumentType contextRef="C">半期報告書</jpdei_cor:DocumentType>
            </xbrli:xbrl>
            """
        try withDir { dir in
            try write(xml, as: "instance.xbrl", in: dir)
            #expect(XBRLParser().detectReportType(in: dir) == "interim")
        }
    }

    @Test func defaultsToAnnualWhenNothingMatches() throws {
        try withDir { dir in
            try write(instanceXml(""), as: "instance.xbrl", in: dir)
            #expect(XBRLParser().detectReportType(in: dir) == "annual")
        }
    }
}
