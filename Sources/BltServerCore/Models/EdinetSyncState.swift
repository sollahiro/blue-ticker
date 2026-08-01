// 書類同期: 増分同期の進捗。ファイルキャッシュの built_through（年別 JSON のメタ）を 1 行へ集約する。
// 単一行（id = 1 固定）で「どこまで同期済みか」を持つ。

import Fluent
import Foundation

/// 書類一覧の同期進捗。単一行（id = 1）。
final class EdinetSyncState: Model, @unchecked Sendable {
    static let schema = "edinet_sync_state"

    /// 単一行の固定主キー。
    static let singletonID = 1

    @ID(custom: "id", generatedBy: .user)
    var id: Int?

    /// 同期済みの最終日（YYYY-MM-DD）。これ以前は DB に取り込み済みとみなす。
    @Field(key: "synced_through")
    var syncedThrough: String

    /// 最終更新時刻。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}
