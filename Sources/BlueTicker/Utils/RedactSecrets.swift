// ログ・CLI エラーに混入しうる秘密情報を 1 箇所でマスクする。
// 呼び出し側ごとの正規表現を増やさず、JsonLogHandler と blt-server の最終エラー出力が共有する。

import Foundation

private let redactSecretReplacements: [(NSRegularExpression, String)] = {
    let patterns: [(pattern: String, template: String)] = [
        (#"(Subscription-Key=)[^&\s"]+"#, "$1***"),
        (#"((?:postgres(?:ql)?://[^:/@\s]+:))[^@\s]+@"#, "$1***@"),
        (#"(Bearer\s+)\S+"#, "$1***"),
    ]
    return patterns.compactMap { item in
        guard let regex = try? NSRegularExpression(pattern: item.pattern) else { return nil }
        return (regex, item.template)
    }
}()

/// EDINET Subscription-Key / Postgres URL の password / Bearer トークンを `***` に置換する。
public func redactSecrets(_ message: String) -> String {
    var result = message
    for (regex, template) in redactSecretReplacements {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
    }
    return result
}
