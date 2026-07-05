// EDINET コードリスト CSV の正本スナップショット。単一行（id = 1）で保持する。
// 手動アップロード（`blt-server master-data-upload`）で更新され、定期ポーリング
// （MasterDataRefresher）でサーバーのローカルファイルへ反映される。
// 正本は CSV の生バイト列（CP932）そのもの。パースは BlueTickerCore の MasterDataManager に一本化する。

import Fluent
import Foundation

/// EDINET コードリスト CSV の正本スナップショット。単一行（id = 1）。
final class EdinetMasterSnapshot: Model, @unchecked Sendable {
    static let schema = "edinet_master_snapshot"

    /// 単一行の固定主キー。
    static let singletonID = 1

    @ID(custom: "id", generatedBy: .user)
    var id: Int?

    /// CSV の生バイト列（CP932 エンコード、無変換のまま保存）。
    @Field(key: "content")
    var content: Data

    /// 最終更新時刻。ポーリングでの変更検知に使う。
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}
