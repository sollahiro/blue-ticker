// 隣接年の報告セグメントつなぎ。スナップショットとは別テーブルなので、
// 判断の訂正に再 ingest は要らない。同じ segment_key の継続は行にしない（暗黙の connect）。

import BlueTickerCore
import FluentKit
import Foundation

package final class CompanySegmentTransition: Model, @unchecked Sendable {
    package static let schema = "company_segment_transitions"

    /// "\(code)#\(fyEnd)#\(oldKey ?? "")#\(newKey ?? "")"
    @ID(custom: "id", generatedBy: .user)
    package var id: String?

    @Field(key: "code")
    package var code: String

    @Field(key: "fy_end")
    package var fyEnd: String

    @OptionalField(key: "old_key")
    package var oldKey: String?

    @OptionalField(key: "new_key")
    package var newKey: String?

    @Field(key: "decision")
    package var decision: String

    @Field(key: "basis")
    package var basis: String

    @Field(key: "matched")
    package var matched: String

    @Field(key: "needs_review")
    package var needsReview: Bool

    @Timestamp(key: "updated_at", on: .update)
    package var updatedAt: Date?

    package init() {}

    package convenience init(
        code: String, fyEnd: String, oldKey: String?, newKey: String?
    ) {
        self.init()
        self.id = Self.compositeID(code: code, fyEnd: fyEnd, oldKey: oldKey, newKey: newKey)
        self.code = code
        self.fyEnd = fyEnd
        self.oldKey = oldKey
        self.newKey = newKey
    }

    package static func compositeID(
        code: String, fyEnd: String, oldKey: String?, newKey: String?
    ) -> String {
        "\(code)#\(fyEnd)#\(oldKey ?? "")#\(newKey ?? "")"
    }
}
