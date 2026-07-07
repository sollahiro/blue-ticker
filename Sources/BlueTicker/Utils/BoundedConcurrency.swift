import Foundation

// MARK: - BoundedConcurrency
// 並列度に上限を設けて重い処理を実行するための共通ヘルパー。
// XBRL ダウンロード＋fact インデックス展開のようにメモリを大量消費する処理を
// 無制限並列で実行するとピークメモリが並列数倍になるため、ウィンドウ方式で制限する。

/// items を最大 limit 並列で transform し、結果（nil を除く）を返す。順序は保証しない。
///
/// 最初に in-flight を最大 limit 件まで addTask し、1件完了するたびに次の1件を addTask する
/// ウィンドウ方式。limit が items.count 以上でも正しく動作する。
func withBoundedTaskGroup<Item: Sendable, Result: Sendable>(
    items: [Item],
    limit: Int,
    transform: @escaping @Sendable (Item) async -> Result?
) async -> [Result] {
    guard !items.isEmpty else { return [] }
    let effectiveLimit = max(1, limit)

    var results: [Result] = []
    var iterator = items.makeIterator()

    await withTaskGroup(of: Result?.self) { group in
        for _ in 0..<min(effectiveLimit, items.count) {
            guard let item = iterator.next() else { break }
            group.addTask { await transform(item) }
        }
        while let next = await group.next() {
            if let r = next { results.append(r) }
            if let item = iterator.next() {
                group.addTask { await transform(item) }
            }
        }
    }
    return results
}
