import Foundation

/// 標準エラー出力へメッセージを書き出す。
///
/// Linux(Glibc) の C `stderr` はグローバル `var` で、Swift 6 言語モードの並行性
/// チェックに通らない（reference to var 'stderr' is not concurrency-safe）。
/// Foundation の `FileHandle.standardError` は Sendable 安全かつクロスプラット
/// フォームなので、stderr への書き出しはこのヘルパーへ集約する。
public func printError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
