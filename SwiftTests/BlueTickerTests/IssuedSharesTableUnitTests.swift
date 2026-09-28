// SPEC_ORACLE: 発行済株式イベント表の金額単位は表内ヘッダーだけでなく
// 直前の「（単位：千円）」キャプションも見る。単位がどこにも無いときは XBRL 資本金と突合し、
// それもできなければ ×1 を黙って使わず needs_review にする（3940 S100XTIP / 7294 S100YGY8）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct IssuedSharesTableUnitTests {

    private static func eventTableHTML(caption: String?, headerAmountUnit: String?) -> String {
        let captionHTML = caption.map { "<p>\($0)</p>\n" } ?? ""
        let amountHeader: String
        if let headerAmountUnit {
            amountHeader =
                "<td>資本金増減額（\(headerAmountUnit)）</td><td>資本金残高（\(headerAmountUnit)）</td>"
                + "<td>資本準備金増減額（\(headerAmountUnit)）</td><td>資本準備金残高（\(headerAmountUnit)）</td>"
        } else {
            amountHeader =
                "<td>資本金増減額</td><td>資本金残高</td>"
                + "<td>資本準備金増減額</td><td>資本準備金残高</td>"
        }
        return """
            \(captionHTML)<table>
              <tr>
                <td>年月日</td>
                <td>発行済株式総数増減数（株）</td>
                <td>発行済株式総数残高（株）</td>
                \(amountHeader)
              </tr>
              <tr>
                <td>2024年4月1日</td>
                <td>1,000</td>
                <td>10,000</td>
                <td>500</td>
                <td>5,000</td>
                <td>－</td>
                <td>3,000</td>
              </tr>
            </table>
            """
    }

    @Test func precedingSenYenCaptionScalesCapitalToYen() throws {
        // 3940 S100XTIP 型: 表内に百万円/千円が無く、直前キャプションが（単位：千円）。
        let html = Self.eventTableHTML(caption: "（単位：千円）", headerAmountUnit: nil)
        let parsed = try #require(
            StatementNotesResolver.parseIssuedSharesEvents(html: html)
        )
        #expect(parsed.needsReview == false)
        #expect(parsed.warnings.isEmpty)
        let event = try #require(parsed.events.first)
        #expect(event.sharesDelta == 1_000)
        #expect(event.capitalDelta == 500_000)
        #expect(event.capitalBalance == 5_000_000)
        #expect(event.capitalReserveBalance == 3_000_000)
    }

    @Test func precedingMillionYenCaptionScalesCapitalToYen() throws {
        // 7294 S100YGY8 型: 表内に単位が無く、直前キャプションが（単位：百万円）。
        let html = Self.eventTableHTML(caption: "（単位：百万円）", headerAmountUnit: nil)
        let parsed = try #require(
            StatementNotesResolver.parseIssuedSharesEvents(html: html)
        )
        #expect(parsed.needsReview == false)
        let event = try #require(parsed.events.first)
        #expect(event.capitalDelta == 500 * Financial.millionYen)
        #expect(event.capitalBalance == 5_000 * Financial.millionYen)
        #expect(event.capitalReserveBalance == 3_000 * Financial.millionYen)
    }

    @Test func inRowMillionYenHeaderStillScalesWithoutCaption() throws {
        let html = Self.eventTableHTML(caption: nil, headerAmountUnit: "百万円")
        let parsed = try #require(
            StatementNotesResolver.parseIssuedSharesEvents(html: html)
        )
        #expect(parsed.needsReview == false)
        let event = try #require(parsed.events.first)
        #expect(event.capitalBalance == 5_000 * Financial.millionYen)
    }

    @Test func xbrlCapitalInfersMillionYenWhenNoUnitToken() throws {
        let html = Self.eventTableHTML(caption: nil, headerAmountUnit: nil)
        let parsed = try #require(
            StatementNotesResolver.parseIssuedSharesEvents(
                html: html, xbrlCapital: 5_000 * Financial.millionYen)
        )
        #expect(parsed.needsReview == false)
        #expect(parsed.warnings.isEmpty)
        let event = try #require(parsed.events.first)
        #expect(event.capitalBalance == 5_000 * Financial.millionYen)
        #expect(event.capitalDelta == 500 * Financial.millionYen)
    }

    @Test func xbrlCapitalInfersThousandYenWhenNoUnitToken() throws {
        let html = Self.eventTableHTML(caption: nil, headerAmountUnit: nil)
        let parsed = try #require(
            StatementNotesResolver.parseIssuedSharesEvents(
                html: html, xbrlCapital: 5_000_000)
        )
        #expect(parsed.needsReview == false)
        let event = try #require(parsed.events.first)
        #expect(event.capitalBalance == 5_000_000)
        #expect(event.capitalDelta == 500_000)
    }

    @Test func missingUnitWithoutXbrlCapitalMarksNeedsReview() throws {
        let html = Self.eventTableHTML(caption: nil, headerAmountUnit: nil)
        let parsed = try #require(
            StatementNotesResolver.parseIssuedSharesEvents(html: html)
        )
        #expect(parsed.needsReview == true)
        #expect(
            parsed.warnings.contains(StatementNotesResolver.issuedSharesUnitUnresolvedWarning))
        let event = try #require(parsed.events.first)
        #expect(event.capitalBalance == 5_000)
        #expect(event.capitalDelta == 500)
    }

    @Test func missingUnitWhenXbrlCapitalDoesNotMatchMarksNeedsReview() throws {
        let html = Self.eventTableHTML(caption: nil, headerAmountUnit: nil)
        let parsed = try #require(
            StatementNotesResolver.parseIssuedSharesEvents(
                html: html, xbrlCapital: 99_999_999)
        )
        #expect(parsed.needsReview == true)
        #expect(
            parsed.warnings.contains(StatementNotesResolver.issuedSharesUnitUnresolvedWarning))
        #expect(
            StatementNotesResolver.inferIssuedSharesYenScale(
                capitalBalances: [5_000], reserveBalances: [3_000],
                xbrlCapital: 99_999_999, xbrlReserve: nil) == nil)
    }
}
