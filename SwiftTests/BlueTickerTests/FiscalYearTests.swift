import Testing
import Foundation
@testable import BlueTicker

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
}
