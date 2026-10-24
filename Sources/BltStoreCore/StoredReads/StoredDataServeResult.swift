import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// DB 格納済みデータ提供の結果。Vapor に依存しないため MCP ディスパッチからも直接呼べる。
package enum StoredDataServeResult {
    /// 成功。JSON 値（`[String: Any]`）。
    case ok([String: Any])
    /// 未格納・未抽出（404 相当）。
    case notFound
    /// DB 未接続・読み取り失敗（503 相当）。
    case dbUnavailable
}
