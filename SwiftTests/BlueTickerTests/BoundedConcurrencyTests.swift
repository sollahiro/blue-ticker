import Testing
@testable import BlueTickerCore

@Suite struct BoundedConcurrencyTests {
    @Test func testAllItemsAreTransformed() async {
        let items = Array(1...5)
        let results = await withBoundedTaskGroup(items: items, limit: 2) { $0 * 10 }
        #expect(Set(results) == Set([10, 20, 30, 40, 50]))
    }

    @Test func testNilResultsAreExcluded() async {
        let items = Array(1...5)
        let results = await withBoundedTaskGroup(items: items, limit: 2) { $0 % 2 == 0 ? $0 : nil }
        #expect(Set(results) == Set([2, 4]))
    }

    @Test func testEmptyItemsReturnsEmptyResult() async {
        let items: [Int] = []
        let results = await withBoundedTaskGroup(items: items, limit: 2) { $0 * 10 }
        #expect(results.isEmpty)
    }

    @Test func testLimitGreaterThanItemCountWorksNormally() async {
        let items = Array(1...3)
        let results = await withBoundedTaskGroup(items: items, limit: 100) { $0 * 10 }
        #expect(Set(results) == Set([10, 20, 30]))
    }

    /// 同時実行数が limit を超えないことを検証する。実装詳細（呼び出し順）ではなく
    /// 並列度上限という仕様を、ピーク並列数を計測して確認する。
    @Test func testConcurrencyNeverExceedsLimit() async {
        let counter = ConcurrencyCounter()
        let limit = 2
        let items = Array(1...20)

        _ = await withBoundedTaskGroup(items: items, limit: limit) { item -> Int? in
            let peak = await counter.increment()
            #expect(peak <= limit)
            try? await Task.sleep(nanoseconds: 1_000_000)
            await counter.decrement()
            return item
        }

        #expect(await counter.observedPeak <= limit)
    }
}

private actor ConcurrencyCounter {
    private var current = 0
    private(set) var observedPeak = 0

    func increment() -> Int {
        current += 1
        observedPeak = max(observedPeak, current)
        return current
    }

    func decrement() {
        current -= 1
    }
}
