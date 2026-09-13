// ログ・CLI エラーに混入しうる秘密情報を 1 箇所でマスクする。
// 呼び出し側ごとの正規表現を増やさず、JsonLogHandler と blt-server の最終エラー出力が共有する。

import Foundation

// 定数パターンのため try!（コンパイル失敗は実装ミスであり、try? で握り潰すと
// マスクが効かないまま秘密情報がログに出る。起動時クラッシュで気づける方が安全）。
private let redactSecretReplacements: [(NSRegularExpression, String)] = [
    (try! NSRegularExpression(pattern: #"(Subscription-Key=)[^&\s"]+"#), "$1***"),
    (try! NSRegularExpression(pattern: #"((?:postgres(?:ql)?://[^:/@\s]+:))[^@\s]+@"#), "$1***@"),
    (try! NSRegularExpression(pattern: #"(Bearer\s+)\S+"#), "$1***"),
]

/// EDINET Subscription-Key / Postgres URL の password / Bearer トークンを `***` に置換する。
public func redactSecrets(_ message: String) -> String {
    var result = message
    for (regex, template) in redactSecretReplacements {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
    }
    return result
}
