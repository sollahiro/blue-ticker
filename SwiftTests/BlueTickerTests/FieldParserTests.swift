// Python tests/test_field_parser.py 相当
// resolveItem / resolveItemPreferCurrent / resolveAggregate / deriveSubtraction /
// fieldSetFromDuration / fieldSetFromInstant を検証する。

import XCTest
@testable import BlueTicker

final class FieldParserTests: XCTestCase {

    // MARK: - resolveItem

    func testResolveItemReturnsFirstMatchingTag() {
        let fs = makeFieldSet(("TagA", 100.0, 90.0), ("TagB", 200.0, 180.0))
        let result = resolveItem(fs, tags: ["TagA", "TagB"])
        XCTAssertEqual(result.tag, "TagA")
        XCTAssertEqual(result.current, 100.0)
        XCTAssertEqual(result.prior, 90.0)
    }

    func testResolveItemSkipsTagWithBothNil() {
        let fs = makeFieldSet(("TagA", nil, nil), ("TagB", 200.0, nil))
        let result = resolveItem(fs, tags: ["TagA", "TagB"])
        XCTAssertEqual(result.tag, "TagB")
        XCTAssertEqual(result.current, 200.0)
    }

    func testResolveItemReturnsTagWithOnlyPrior() {
        let fs = makeFieldSet(("TagA", nil, 90.0))
        let result = resolveItem(fs, tags: ["TagA"])
        XCTAssertEqual(result.tag, "TagA")
        XCTAssertNil(result.current)
        XCTAssertEqual(result.prior, 90.0)
    }

    func testResolveItemNotFoundReturnsNilTag() {
        let fs = makeFieldSet(("TagX", nil, nil))
        let result = resolveItem(fs, tags: ["TagA", "TagB"])
        XCTAssertNil(result.tag)
        XCTAssertNil(result.current)
        XCTAssertNil(result.prior)
    }

    func testResolveItemEmptyCandidates() {
        let fs = makeFieldSet(("TagA", 100.0, nil))
        let result = resolveItem(fs, tags: [])
        XCTAssertNil(result.tag)
    }

    // MARK: - resolveItemPreferCurrent

    func testPreferCurrentPrefersTagWithCurrentValue() {
        let fs = makeFieldSet(("TagA", nil, 90.0), ("TagB", 200.0, nil))
        let result = resolveItemPreferCurrent(fs, tags: ["TagA", "TagB"])
        XCTAssertEqual(result.tag, "TagB")
        XCTAssertEqual(result.current, 200.0)
    }

    func testPreferCurrentFallsBackToPriorOnly() {
        let fs = makeFieldSet(("TagA", nil, 90.0))
        let result = resolveItemPreferCurrent(fs, tags: ["TagA"])
        XCTAssertEqual(result.tag, "TagA")
        XCTAssertNil(result.current)
        XCTAssertEqual(result.prior, 90.0)
    }

    func testPreferCurrentReturnsFirstCurrentAmongCandidates() {
        let fs = makeFieldSet(("TagA", 100.0, nil), ("TagB", 200.0, nil))
        let result = resolveItemPreferCurrent(fs, tags: ["TagA", "TagB"])
        XCTAssertEqual(result.tag, "TagA")
    }

    func testPreferCurrentNotFoundReturnsNilTag() {
        let result = resolveItemPreferCurrent([:], tags: ["TagA"])
        XCTAssertNil(result.tag)
    }

    // MARK: - resolveAggregate

    func testAggregateSumsAllComponents() {
        let fs = makeFieldSet(("TagA", 100.0, 90.0), ("TagB", 200.0, 180.0))
        let result = resolveAggregate(fs, componentTagLists: [["TagA"], ["TagB"]])
        XCTAssertEqual(result.current!, 300.0, accuracy: 1e-9)
        XCTAssertEqual(result.prior!, 270.0, accuracy: 1e-9)
    }

    func testAggregatePartialComponentsStillAggregate() {
        let fs = makeFieldSet(("TagA", 100.0, nil))
        let result = resolveAggregate(fs, componentTagLists: [["TagA"], ["TagB"]])
        XCTAssertEqual(result.current, 100.0)
        XCTAssertNil(result.prior)
    }

    func testAggregateNoComponentsFound() {
        let result = resolveAggregate([:], componentTagLists: [["TagA"], ["TagB"]])
        XCTAssertNil(result.tag)
        XCTAssertNil(result.current)
        XCTAssertNil(result.prior)
    }

    func testAggregateTagIsJoinedWithPlus() {
        let fs = makeFieldSet(("TagA", 100.0, nil), ("TagB", 200.0, nil))
        let result = resolveAggregate(fs, componentTagLists: [["TagA"], ["TagB"]])
        XCTAssertTrue((result.tag ?? "").contains("TagA"))
        XCTAssertTrue((result.tag ?? "").contains("TagB"))
    }

    // MARK: - deriveSubtraction

    func testDeriveSubtractsValues() {
        let fs = makeFieldSet(("Total", 500.0, 450.0), ("Cost", 200.0, 180.0))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        XCTAssertEqual(result.current!, 300.0, accuracy: 1e-9)
        XCTAssertEqual(result.prior!, 270.0, accuracy: 1e-9)
    }

    func testDeriveNilMinuendReturnsNil() {
        let fs = makeFieldSet(("Total", nil, nil), ("Cost", 200.0, 180.0))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        XCTAssertNil(result.current)
        XCTAssertNil(result.prior)
    }

    func testDeriveNilSubtrahendReturnsNil() {
        let fs = makeFieldSet(("Total", 500.0, 450.0))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        XCTAssertNil(result.current)
        XCTAssertNil(result.prior)
    }

    func testDeriveTagContainsMinusSeparator() {
        let fs = makeFieldSet(("Total", 500.0, nil), ("Cost", 200.0, nil))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        XCTAssertTrue((result.tag ?? "").contains("-"))
    }

    // MARK: - fieldSetFromDuration

    func testDurationExactCurrentYearDuration() {
        let tagElements: XbrlTagElements = [
            "Sales": [
                "CurrentYearDuration": 1000.0,
                "Prior1YearDuration": 900.0,
            ]
        ]
        let fs = fieldSetFromDuration(tagElements)
        XCTAssertEqual(fs["Sales"]?.current, 1000.0)
        XCTAssertEqual(fs["Sales"]?.prior, 900.0)
    }

    func testDurationConsolidatedMemberSuffixExcluded() {
        // Member 末尾はセグメント軸として連結コンテキストに認識されない
        // （存在記録として current=nil のマーカーにはなる）
        let tagElements: XbrlTagElements = [
            "Sales": ["CurrentYearDuration_ConsolidatedMember": 1000.0]
        ]
        let fs = fieldSetFromDuration(tagElements)
        XCTAssertNil(fs["Sales"]?.current ?? nil)
    }

    func testDurationNonMemberSuffixAccepted() {
        // Member で終わらない連結コンテキストはフォールバックで拾われる
        let tagElements: XbrlTagElements = [
            "Sales": ["CurrentYearDuration_SomeSegment": 1000.0]
        ]
        let fs = fieldSetFromDuration(tagElements)
        XCTAssertEqual(fs["Sales"]?.current, 1000.0)
    }

    func testDurationEmptyInputReturnsEmpty() {
        XCTAssertTrue(fieldSetFromDuration([:]).isEmpty)
    }

    func testDurationIncludesInstantOnlyTagsAsMarkers() {
        // Instant のみのタグは存在記録として current=nil で含まれる
        let tagElements: XbrlTagElements = [
            "SomeMarker": ["CurrentYearInstant": 1.0]
        ]
        let fs = fieldSetFromDuration(tagElements)
        XCTAssertNotNil(fs["SomeMarker"])
        XCTAssertNil(fs["SomeMarker"]?.current ?? nil)
    }

    // MARK: - fieldSetFromInstant

    func testInstantExactCurrentYearInstant() {
        let tagElements: XbrlTagElements = [
            "Assets": [
                "CurrentYearInstant": 5000.0,
                "Prior1YearInstant": 4500.0,
            ]
        ]
        let fs = fieldSetFromInstant(tagElements)
        XCTAssertEqual(fs["Assets"]?.current, 5000.0)
        XCTAssertEqual(fs["Assets"]?.prior, 4500.0)
    }

    func testInstantEmptyInputReturnsEmpty() {
        XCTAssertTrue(fieldSetFromInstant([:]).isEmpty)
    }
}
