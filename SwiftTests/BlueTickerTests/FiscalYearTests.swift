import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct FiscalYearTests {
    @Test func testNormalizeDateFormatCompact() {
        #expect(normalizeDateFormat("20231231") == "2023-12-31")
    }

    @Test func testNormalizeDateFormatHyphenated() {
        #expect(normalizeDateFormat("2023-12-31") == "2023-12-31")
    }

    @Test func testNormalizeDateFormatNil() {
        #expect(normalizeDateFormat(nil) == nil)
        #expect(normalizeDateFormat("") == nil)
    }

    @Test func testNormalizeDateFormatIdempotent() {
        let result = normalizeDateFormat("2023-12-31")
        #expect(normalizeDateFormat(result) == "2023-12-31")
    }

    @Test func testCalculateFiscalYearMarch() {
        // 3月期（月 < 12）→ year - 1
        #expect(calculateFiscalYear(fyEnd: "2024-03-31") == 2023)
    }

    @Test func testCalculateFiscalYearDecember() {
        // 12月期 → year
        #expect(calculateFiscalYear(fyEnd: "2023-12-31") == 2023)
    }

    @Test func testCalculateFiscalYearWithStart() {
        // fyStart が提供された場合は開始年を優先
        #expect(calculateFiscalYear(fyEnd: "2024-03-31", fyStart: "2023-04-01") == 2023)
    }

    @Test func testExtractYearMonth() {
        let (year, month) = extractYearMonth("20231231")
        #expect(year == 2023)
        #expect(month == 12)
    }

    // MARK: - parseDateString

    @Test func parseDateStringReturnsDateForCompactFormat() {
        let date = parseDateString("20231231")
        #expect(date != nil)
        #expect(date.map(formatDateString) == "2023-12-31")
    }

    @Test func parseDateStringReturnsDateForHyphenatedFormat() {
        let date = parseDateString("2023-12-31")
        #expect(date != nil)
        #expect(date.map(formatDateString) == "2023-12-31")
    }

    @Test func parseDateStringReturnsNilForNilInput() {
        #expect(parseDateString(nil) == nil)
    }

    @Test func parseDateStringReturnsNilForInvalidCompactCalendarDate() {
        // コンパクト形式（YYYYMMDD）は DateFormatter によるカレンダー妥当性検証を通る
        // （存在しない13月は拒否される）。
        #expect(parseDateString("20231345") == nil)
    }

    @Test func parseDateStringReturnsNilForMalformedInput() {
        #expect(parseDateString("not-a-date") == nil)
    }

    // MARK: - formatDateString

    @Test func formatDateStringUsesUTCRegardlessOfLocalCalendarDay() throws {
        // 2023-12-31 23:59:59 UTC は UTC 以外のタイムゾーンでは別日になり得るが、
        // formatDateString は UTC 固定の isoFormatter を使うため "2023-12-31" を返す。
        let comps = DateComponents(year: 2023, month: 12, day: 31, hour: 23, minute: 59, second: 59)
        let date = try #require(utcCalendar.date(from: comps))
        #expect(formatDateString(date) == "2023-12-31")
    }

    // MARK: - dayBeforeISO

    @Test func dayBeforeISOReturnsLeapDayForMarchFirstInLeapYear() {
        #expect(dayBeforeISO("2024-03-01") == "2024-02-29")
    }

    @Test func dayBeforeISOReturnsFeb28ForMarchFirstInNonLeapYear() {
        #expect(dayBeforeISO("2023-03-01") == "2023-02-28")
    }

    @Test func dayBeforeISOReturnsPriorYearLastDayForJanuaryFirst() {
        #expect(dayBeforeISO("2024-01-01") == "2023-12-31")
    }

    @Test func dayBeforeISOReturnsNilForInvalidInput() {
        #expect(dayBeforeISO("not-a-date") == nil)
    }

    // MARK: - normalizeDateFormat（異常系）

    @Test func normalizeDateFormatReturnsNilForNonNumericInputOfCompactLength() {
        // 8文字だが数字でない入力はハイフン区切りの最小長（10）にも満たないため nil。
        #expect(normalizeDateFormat("abcd1234") == nil)
    }

    @Test func normalizeDateFormatReturnsNilForInvalidHyphenatedCalendarDate() {
        // ハイフン区切り入力は DateFormatter によるカレンダー妥当性検証を通る
        // （存在しない13月・45日は拒否される）。
        #expect(normalizeDateFormat("2023-13-45") == nil)
    }

    // MARK: - calculateFiscalYear（異常系）

    @Test func calculateFiscalYearReturnsNilForNilFyEnd() {
        #expect(calculateFiscalYear(fyEnd: nil) == nil)
    }

    @Test func calculateFiscalYearReturnsNilForInvalidFyEnd() {
        #expect(calculateFiscalYear(fyEnd: "not-a-date") == nil)
    }
}
