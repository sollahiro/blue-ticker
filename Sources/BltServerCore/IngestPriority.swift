// Stage 4/4-half/5 共通の候補列並び替え。ユーザーが用意した優先コード一覧
// （`assets/nikkei225.csv`、`BltServerContext.priorityIngestCodes()`）を候補選定の後段で
// 先頭へ寄せる。対象選定（何を取り込むか）ではなく処理順序（何から取り込むか）のみを変える。

/// `priorityCodes` に含まれる要素を安定に先頭へ寄せる（同集合内・非対象内それぞれの相対順序は保持）。
/// `priorityCodes` が空なら無並び替え（従来どおりの順序）。
func prioritized<T>(_ candidates: [T], codeOf: (T) -> String, priorityCodes: Set<String>) -> [T] {
    guard !priorityCodes.isEmpty else { return candidates }
    var head: [T] = []
    var tail: [T] = []
    for candidate in candidates {
        if priorityCodes.contains(codeOf(candidate)) {
            head.append(candidate)
        } else {
            tail.append(candidate)
        }
    }
    return head + tail
}
