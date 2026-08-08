// 会社アイコン取り込み: 会社1社=1行で favicon の R2 格納先を保持する。実バイナリは R2 に置き、
// このテーブルは R2 オブジェクトキーと取得元・抽出バージョンのみを持つ（他テーブルの JSONB payload
// 方式とは異なり、REST read は r2_object_key から公開URLを組み立てるだけで済むため）。

import BlueTickerCore
import Fluent
import Foundation

/// 会社1社分の favicon 格納メタデータ。証券コードを主キー（user 生成）とする。
final class CompanyIcon: Model, @unchecked Sendable {
    static let schema = "company_icons"

    /// 4 桁証券コード（例: 7203）。
    @ID(custom: "code", generatedBy: .user)
    var id: String?

    /// 抽出元の電子公告URL（`CorporateWebsiteExtractor` が返す scheme://host）。
    @Field(key: "source_url")
    var sourceURL: String

    /// R2 バケット内のオブジェクトキー。公開URLは `R2PublicURLConfig.publicURL(forKey:)`（read経路）
    /// または `R2Config.publicURL(forKey:)`（アップロード経路）で組み立てる。
    @Field(key: "r2_object_key")
    var r2ObjectKey: String

    /// favicon 実体の MIME（`FaviconFetcher.sniffImageContentType` の判定結果）。
    @Field(key: "content_type")
    var contentType: String

    /// 取得時の companyIconsCacheVersion。読込・取り込みで照合し、不一致なら再取得する。
    @Field(key: "cache_version")
    var cacheVersion: String

    /// 最終取得時刻（favicon を取得し R2 へアップロードしたタイミング）。
    @Timestamp(key: "fetched_at", on: .update)
    var fetchedAt: Date?

    init() {}

    init(code: String, sourceURL: String, r2ObjectKey: String, contentType: String, cacheVersion: String) {
        self.id = code
        self.sourceURL = sourceURL
        self.r2ObjectKey = r2ObjectKey
        self.contentType = contentType
        self.cacheVersion = cacheVersion
    }
}
