// 成功時の冗長ログを既定で抑制する（`.agents/skills/xbrl-development/SKILL.md` Spec 層）。
// `BLT_TEST_VERBOSE=1` のときだけ stdout に出す。失敗詳細は `#expect` / `Issue.record` に載せる。

import Foundation

enum TestVerboseLog {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["BLT_TEST_VERBOSE"] == "1"
    }

    static func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        guard enabled else { return }
        let line = items.map { String(describing: $0) }.joined(separator: separator)
        Swift.print(line, terminator: terminator)
    }
}
