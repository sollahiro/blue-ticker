import XCTest
@testable import BlueTicker

final class ConvertersTests: XCTestCase {
    func testToFloatFromDouble() {
        XCTAssertEqual(toFloat(1.5), 1.5)
    }

    func testToFloatFromString() {
        XCTAssertEqual(toFloat("3.14"), 3.14)
    }

    func testToFloatNaN() {
        XCTAssertNil(toFloat(Double.nan))
    }

    func testToFloatNil() {
        XCTAssertNil(toFloat(nil))
    }

    func testIsValidValue() {
        XCTAssertTrue(isValidValue(1.0))
        XCTAssertFalse(isValidValue(nil))
        XCTAssertFalse(isValidValue(Double.nan))
        XCTAssertFalse(isValidValue(Double.infinity))
    }

    func testIsFutureDate() {
        XCTAssertFalse(isFutureDate("2020-01-01"))
        XCTAssertTrue(isFutureDate("2099-12-31"))
    }
}
