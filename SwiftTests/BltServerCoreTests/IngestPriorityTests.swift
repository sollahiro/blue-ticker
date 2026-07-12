// Stage 4/4-half/5 共通の候補並び替え（prioritized）の仕様を検証する。
// 対象選定ではなく処理順序のみを変えること・元の相対順序を保つ（安定ソート）ことを確認する。

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
}
