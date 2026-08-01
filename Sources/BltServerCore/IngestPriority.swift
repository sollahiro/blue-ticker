// financials/half-financials/filing-sections/breakdowns 共通の候補列並び替え。ユーザーが用意した優先コード一覧
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

/// 複数バケツ（優先度の高い順）の候補をラウンドロビンで束ねる。単純連結（`a + b + c`）だと
/// 上位バケツが `limit` を埋め続ける限り下位バケツが未来永劫処理されない（starvation）。
/// 各ラウンドで先頭バケツから順に1件ずつ取り出すことで、`limit` がバケツ数以上ある限り
/// 全バケツに毎サイクル一定の進捗を保証する。バケツ内の相対順序・バケツ間の優先順位
/// （同ラウンド内の並び）は維持する。
func interleaved<T>(_ buckets: [[T]]) -> [T] {
    var result: [T] = []
    result.reserveCapacity(buckets.reduce(0) { $0 + $1.count })
    var indices = [Int](repeating: 0, count: buckets.count)
    var remaining = buckets.reduce(0) { $0 + $1.count }
    while remaining > 0 {
        for i in buckets.indices where indices[i] < buckets[i].count {
            result.append(buckets[i][indices[i]])
            indices[i] += 1
            remaining -= 1
        }
    }
    return result
}
