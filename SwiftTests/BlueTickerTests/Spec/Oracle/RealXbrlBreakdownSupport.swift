// RealXbrl breakdown Oracle 実行器の共有ハーネス（L1）。
// `BLT_EDINET_API_KEY` があれば SmokeCacheSupport で不足キャッシュを取得する。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

actor RealXbrlMockChat: ChatCompleting {
    private let responseJSON: [String: Any]?
    private(set) var callCount = 0
    private(set) var lastSchemaName: String?

    init(responseJSON: [String: Any]?) {
        self.responseJSON = responseJSON
    }

    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        callCount += 1
        lastSchemaName = schemaName
        guard let responseJSON else { throw ChatCompletionError.emptyContent }
        return try JSONSerialization.data(withJSONObject: responseJSON)
    }

    func timesCalled() async -> Int { callCount }
    func schemaName() async -> String? { lastSchemaName }
}

