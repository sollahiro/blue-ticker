// Python tests/test_field_parser.py 相当
// resolveItem / resolveItemPreferCurrent / resolveAggregate / deriveSubtraction /
// fieldSetFromDuration / fieldSetFromInstant を検証する。

import Testing
import Foundation
@testable import BlueTicker

@Suite struct FieldParserTests {

    // MARK: - resolveItem

    @Test func testResolveItemReturnsFirstMatchingTag() {
        let fs = makeFieldSet(("TagA", 100.0, 90.0), ("TagB", 200.0, 180.0))
        let result = resolveItem(fs, tags: ["TagA", "TagB"])
        #expect(result.tag == "TagA")
        #expect(result.current == 100.0)
        #expect(result.prior == 90.0)
    }

    @Test func testResolveItemSkipsTagWithBothNil() {
        let fs = makeFieldSet(("TagA", nil, nil), ("TagB", 200.0, nil))
        let result = resolveItem(fs, tags: ["TagA", "TagB"])
        #expect(result.tag == "TagB")
        #expect(result.current == 200.0)
    }

    @Test func testResolveItemReturnsTagWithOnlyPrior() {
        let fs = makeFieldSet(("TagA", nil, 90.0))
        let result = resolveItem(fs, tags: ["TagA"])
        #expect(result.tag == "TagA")
        #expect(result.current == nil)
        #expect(result.prior == 90.0)
    }

    @Test func testResolveItemNotFoundReturnsNilTag() {
        let fs = makeFieldSet(("TagX", nil, nil))
        let result = resolveItem(fs, tags: ["TagA", "TagB"])
        #expect(result.tag == nil)
        #expect(result.current == nil)
        #expect(result.prior == nil)
    }

    @Test func testResolveItemEmptyCandidates() {
        let fs = makeFieldSet(("TagA", 100.0, nil))
        let result = resolveItem(fs, tags: [])
        #expect(result.tag == nil)
    }

    // MARK: - resolveItemPreferCurrent

    @Test func testPreferCurrentPrefersTagWithCurrentValue() {
        let fs = makeFieldSet(("TagA", nil, 90.0), ("TagB", 200.0, nil))
        let result = resolveItemPreferCurrent(fs, tags: ["TagA", "TagB"])
        #expect(result.tag == "TagB")
        #expect(result.current == 200.0)
    }

    @Test func testPreferCurrentFallsBackToPriorOnly() {
        let fs = makeFieldSet(("TagA", nil, 90.0))
        let result = resolveItemPreferCurrent(fs, tags: ["TagA"])
        #expect(result.tag == "TagA")
        #expect(result.current == nil)
        #expect(result.prior == 90.0)
    }

    @Test func testPreferCurrentReturnsFirstCurrentAmongCandidates() {
        let fs = makeFieldSet(("TagA", 100.0, nil), ("TagB", 200.0, nil))
        let result = resolveItemPreferCurrent(fs, tags: ["TagA", "TagB"])
        #expect(result.tag == "TagA")
    }

    @Test func testPreferCurrentNotFoundReturnsNilTag() {
        let result = resolveItemPreferCurrent([:], tags: ["TagA"])
        #expect(result.tag == nil)
    }

    // MARK: - resolveAggregate

    @Test func testAggregateSumsAllComponents() {
        let fs = makeFieldSet(("TagA", 100.0, 90.0), ("TagB", 200.0, 180.0))
        let result = resolveAggregate(fs, componentTagLists: [["TagA"], ["TagB"]])
        #expect(abs((result.current!) - (300.0)) <= (1e-9))
        #expect(abs((result.prior!) - (270.0)) <= (1e-9))
    }

    @Test func testAggregatePartialComponentsStillAggregate() {
        let fs = makeFieldSet(("TagA", 100.0, nil))
        let result = resolveAggregate(fs, componentTagLists: [["TagA"], ["TagB"]])
        #expect(result.current == 100.0)
        #expect(result.prior == nil)
    }

    @Test func testAggregateNoComponentsFound() {
        let result = resolveAggregate([:], componentTagLists: [["TagA"], ["TagB"]])
        #expect(result.tag == nil)
        #expect(result.current == nil)
        #expect(result.prior == nil)
    }

    @Test func testAggregateTagIsJoinedWithPlus() {
        let fs = makeFieldSet(("TagA", 100.0, nil), ("TagB", 200.0, nil))
        let result = resolveAggregate(fs, componentTagLists: [["TagA"], ["TagB"]])
        #expect((result.tag ?? "").contains("TagA"))
        #expect((result.tag ?? "").contains("TagB"))
    }

    // MARK: - deriveSubtraction

    @Test func testDeriveSubtractsValues() {
        let fs = makeFieldSet(("Total", 500.0, 450.0), ("Cost", 200.0, 180.0))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        #expect(abs((result.current!) - (300.0)) <= (1e-9))
        #expect(abs((result.prior!) - (270.0)) <= (1e-9))
    }

    @Test func testDeriveNilMinuendReturnsNil() {
        let fs = makeFieldSet(("Total", nil, nil), ("Cost", 200.0, 180.0))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        #expect(result.current == nil)
        #expect(result.prior == nil)
    }

    @Test func testDeriveNilSubtrahendReturnsNil() {
        let fs = makeFieldSet(("Total", 500.0, 450.0))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        #expect(result.current == nil)
        #expect(result.prior == nil)
    }

    @Test func testDeriveTagContainsMinusSeparator() {
        let fs = makeFieldSet(("Total", 500.0, nil), ("Cost", 200.0, nil))
        let result = deriveSubtraction(fs, minuendTags: ["Total"], subtrahendTags: ["Cost"])
        #expect((result.tag ?? "").contains("-"))
    }

    // MARK: - fieldSetFromDuration

    @Test func testDurationExactCurrentYearDuration() {
        let tagElements: XbrlTagElements = [
            "Sales": [
                "CurrentYearDuration": 1000.0,
                "Prior1YearDuration": 900.0,
            ]
        ]
        let fs = fieldSetFromDuration(tagElements)
        #expect(fs["Sales"]?.current == 1000.0)
        #expect(fs["Sales"]?.prior == 900.0)
    }

    @Test func testDurationConsolidatedMemberSuffixExcluded() {
        // Member 末尾はセグメント軸として連結コンテキストに認識されない
        // （存在記録として current=nil のマーカーにはなる）
        let tagElements: XbrlTagElements = [
            "Sales": ["CurrentYearDuration_ConsolidatedMember": 1000.0]
        ]
        let fs = fieldSetFromDuration(tagElements)
        #expect(fs["Sales"]?.current ?? nil == nil)
    }

    @Test func testDurationNonMemberSuffixAccepted() {
        // Member で終わらない連結コンテキストはフォールバックで拾われる
        let tagElements: XbrlTagElements = [
            "Sales": ["CurrentYearDuration_SomeSegment": 1000.0]
        ]
        let fs = fieldSetFromDuration(tagElements)
        #expect(fs["Sales"]?.current == 1000.0)
    }

    @Test func testDurationEmptyInputReturnsEmpty() {
        #expect(fieldSetFromDuration([:]).isEmpty)
    }

    @Test func testDurationIncludesInstantOnlyTagsAsMarkers() {
        // Instant のみのタグは存在記録として current=nil で含まれる
        let tagElements: XbrlTagElements = [
            "SomeMarker": ["CurrentYearInstant": 1.0]
        ]
        let fs = fieldSetFromDuration(tagElements)
        #expect(fs["SomeMarker"] != nil)
        #expect(fs["SomeMarker"]?.current ?? nil == nil)
    }

    // MARK: - fieldSetFromInstant

    @Test func testInstantExactCurrentYearInstant() {
        let tagElements: XbrlTagElements = [
            "Assets": [
                "CurrentYearInstant": 5000.0,
                "Prior1YearInstant": 4500.0,
            ]
        ]
        let fs = fieldSetFromInstant(tagElements)
        #expect(fs["Assets"]?.current == 5000.0)
        #expect(fs["Assets"]?.prior == 4500.0)
    }

    @Test func testInstantEmptyInputReturnsEmpty() {
        #expect(fieldSetFromInstant([:]).isEmpty)
    }
}
