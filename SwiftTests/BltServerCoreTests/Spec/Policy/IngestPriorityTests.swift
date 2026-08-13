// 候補並び替え（prioritized / ingestOrdered）の仕様を検証する。
// 対象選定ではなく処理順序のみを変えること・元の相対順序を保つ（安定ソート）ことを確認する。
// 書類単位 ingest はキャッシュ済み docID と日経225 を重ねる（後段の日経225が勝つ）。

import Testing

@testable import BltServerCore

@Suite("prioritized")
struct IngestPriorityTests {
    @Test("優先コードを先頭へ安定に寄せる")
    func movesPriorityCodesToFrontStably() {
        let items = ["7203", "6758", "9984", "8306"]
        let result = prioritized(items, codeOf: { $0 }, priorityCodes: ["9984", "8306"])
        #expect(result == ["9984", "8306", "7203", "6758"])
    }

    @Test("優先集合が空なら元の順序のまま")
    func emptyPriorityLeavesOrderUnchanged() {
        let items = ["7203", "6758", "9984"]
        #expect(prioritized(items, codeOf: { $0 }, priorityCodes: []) == items)
    }

    @Test("優先集合に一致するコードが無ければ元の順序のまま")
    func noMatchesLeaveOrderUnchanged() {
        let items = ["7203", "6758"]
        #expect(prioritized(items, codeOf: { $0 }, priorityCodes: ["9984"]) == items)
    }

    @Test("キャッシュ優先の上に日経225を重ねると225が勝つ")
    func nikkeiPriorityOutranksCachedDocIDs() {
        struct Item: Equatable { let docID: String; let code: String }
        let items = [
            Item(docID: "cached-other", code: "9999"),
            Item(docID: "uncached-225", code: "7203"),
        ]
        let result = ingestOrdered(
            items, docIDOf: \.docID, codeOf: \.code,
            cachedDocIDs: ["cached-other"], priorityCodes: ["7203"])
        #expect(result.map(\.docID) == ["uncached-225", "cached-other"])
    }

    @Test("同じ日経225内ではキャッシュ済みが先")
    func cachedDocIDsWinWithinSameNikkeiGroup() {
        struct Item: Equatable { let docID: String; let code: String }
        let items = [
            Item(docID: "uncached-225", code: "7203"),
            Item(docID: "cached-225", code: "6758"),
        ]
        let result = ingestOrdered(
            items, docIDOf: \.docID, codeOf: \.code,
            cachedDocIDs: ["cached-225"], priorityCodes: ["7203", "6758"])
        #expect(result.map(\.docID) == ["cached-225", "uncached-225"])
    }
}

@Suite("interleaved")
struct InterleavedTests {
    @Test("複数バケツをラウンドロビンで束ねる（バケツ間の優先順位・バケツ内の相対順序は維持）")
    func roundRobinsAcrossBuckets() {
        let result = interleaved([["a1", "a2"], ["b1", "b2"], ["c1", "c2"]])
        #expect(result == ["a1", "b1", "c1", "a2", "b2", "c2"])
    }

    @Test("空バケツはスキップされる")
    func skipsEmptyBuckets() {
        let result = interleaved([["a1"], [], ["c1", "c2"]])
        #expect(result == ["a1", "c1", "c2"])
    }

    @Test("上位バケツが limit を大きく超える件数でも下位バケツが飢餓状態にならない")
    func lowerPriorityBucketIsNotStarvedByLargerBucket() {
        let big = (1...100).map { "big\($0)" }
        let result = interleaved([big, ["small1"]])
        #expect(result[1] == "small1")
    }

    @Test("全バケツが空なら空配列")
    func allEmptyBucketsProduceEmptyResult() {
        #expect(interleaved([[String](), [String]()]) == [])
    }
}
