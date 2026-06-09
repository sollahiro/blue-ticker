import XCTest
@testable import BlueTicker

final class FiscalYearTests: XCTestCase {
    func testNormalizeDateFormatCompact() {
        XCTAssertEqual(normalizeDateFormat("20231231"), "2023-12-31")
    }

    func testNormalizeDateFormatHyphenated() {
        XCTAssertEqual(normalizeDateFormat("2023-12-31"), "2023-12-31")
    }

    func testNormalizeDateFormatNil() {
        XCTAssertNil(normalizeDateFormat(nil))
        XCTAssertNil(normalizeDateFormat(""))
    }

    func testNormalizeDateFormatIdempotent() {
        let result = normalizeDateFormat("2023-12-31")
        XCTAssertEqual(normalizeDateFormat(result), "2023-12-31")
    }

    func testCalculateFiscalYearMarch() {
        // 3月期（月 < 12）→ year - 1
        XCTAssertEqual(calculateFiscalYear(fyEnd: "2024-03-31"), 2023)
    }

    func testCalculateFiscalYearDecember() {
        // 12月期 → year
        XCTAssertEqual(calculateFiscalYear(fyEnd: "2023-12-31"), 2023)
    }

    func testCalculateFiscalYearWithStart() {
        // fyStart が提供された場合は開始年を優先
        XCTAssertEqual(calculateFiscalYear(fyEnd: "2024-03-31", fyStart: "2023-04-01"), 2023)
    }

    func testExtractYearMonth() {
        let (year, month) = extractYearMonth("20231231")
        XCTAssertEqual(year, 2023)
        XCTAssertEqual(month, 12)
    }
}
