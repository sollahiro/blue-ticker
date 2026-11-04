// 会社アイコン: 会社1社=1行で R2 格納先を保持する。実バイナリは R2 に置き、
// このテーブルは R2 オブジェクトキーと取得元・cache_version のみを持つ（他テーブルの JSONB payload
// 方式とは異なり、REST read は r2_object_key から公開URLを組み立てるだけで済むため）。

import BlueTickerCore
import FluentKit
import Foundation

/// 会社1社分のアイコン格納メタデータ。証券コードを主キー（user 生成）とする。
package final class CompanyIcon: Model, @unchecked Sendable {
    package static let schema = "company_icons"

    /// 4 桁証券コード（例: 7203）。
    @ID(custom: "code", generatedBy: .user)
    package var id: String?

    /// 取得元 URL（歴史的。ingest 廃止後は既存行の値を保持するだけ）。
    @Field(key: "source_url")
    package var sourceURL: String

    /// R2 バケット内のオブジェクトキー。公開URLは `R2PublicURLConfig.publicURL(forKey:)` で組み立てる。
    @Field(key: "r2_object_key")
    package var r2ObjectKey: String

    /// 画像の MIME。
    @Field(key: "content_type")
    package var contentType: String

    /// 格納時の cache_version（歴史的。ingest 廃止後は照合しない）。
    @Field(key: "cache_version")
    package var cacheVersion: String

    /// 最終更新時刻。
    @Timestamp(key: "fetched_at", on: .update)
    package var fetchedAt: Date?

    package init() {}

    package init(code: String, sourceURL: String, r2ObjectKey: String, contentType: String, cacheVersion: String) {
        self.id = code
        self.sourceURL = sourceURL
        self.r2ObjectKey = r2ObjectKey
        self.contentType = contentType
        self.cacheVersion = cacheVersion
    }
}
