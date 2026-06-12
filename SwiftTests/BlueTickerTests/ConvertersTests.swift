import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct ConvertersTests {
    @Test func testToFloatFromDouble() {
        #expect(toFloat(1.5) == 1.5)
    }

    @Test func testToFloatFromString() {
        #expect(toFloat("3.14") == 3.14)
    }

    @Test func testToFloatNaN() {
        #expect(toFloat(Double.nan) == nil)
    }

    @Test func testToFloatNil() {
        #expect(toFloat(nil) == nil)
    }

    @Test func testIsValidValue() {
        #expect(isValidValue(1.0))
        #expect(!(isValidValue(nil)))
        #expect(!(isValidValue(Double.nan)))
        #expect(!(isValidValue(Double.infinity)))
    }

    @Test func testIsFutureDate() {
        #expect(!(isFutureDate("2020-01-01")))
        #expect(isFutureDate("2099-12-31"))
    }
}
