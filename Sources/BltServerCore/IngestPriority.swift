// 候補列の並び替え。対象選定（何を取り込むか）ではなく処理順序（何から取り込むか）のみを変える。
// 日経225（`assets/nikkei225.csv`）とローカル XBRL 展開済み docID を重ねる。

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

/// 軽量射影行を主キーで引ける辞書にする（分類の N+1 find 回避用）。
func ingestIndexByID<T>(_ rows: [T], idOf: (T) -> String?) -> [String: T] {
    var index: [String: T] = [:]
    index.reserveCapacity(rows.count)
    for row in rows {
        if let id = idOf(row) { index[id] = row }
    }
    return index
}

/// 書類単位 ingest の処理順: 日経225 → ローカル XBRL 展開済み → 元の相対順。
/// `prioritized` をキャッシュ向け・コード向けの順に重ねる（後段の日経225が勝つ）。
func ingestOrdered<T>(
    _ candidates: [T], docIDOf: (T) -> String, codeOf: (T) -> String,
    cachedDocIDs: Set<String>, priorityCodes: Set<String>
) -> [T] {
    prioritized(
        prioritized(candidates, codeOf: docIDOf, priorityCodes: cachedDocIDs),
        codeOf: codeOf, priorityCodes: priorityCodes)
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
