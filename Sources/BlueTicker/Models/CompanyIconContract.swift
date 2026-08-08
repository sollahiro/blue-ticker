// 会社アイコン取り込み（EDINET電子公告URL→favicon→R2）の格納用バージョン定数。
// company_icons.cache_version（Neon）に埋め込む。blueTickerVersion 非連動（fin-v2 / facts-v1 と
// 同思想）。CorporateWebsiteExtractor の抽出ロジック、または FaviconFetcher の取得・判定ロジックを
// 変更したときのみバンプする。

import Foundation

/// Neon 会社アイコン取り込み キャッシュ（company_icons.cache_version）の抽出バージョン。
public let companyIconsCacheVersion = "icons-v1"

/// 会社アイコン取り込み（1書類分）の抽出・アップロード結果。R2への格納が完了した状態のみを表す
/// （途中失敗は戻り値パターンにより nil。`BltServerContext.extractAndUploadCompanyIcon` が返す）。
public struct CompanyIconExtractResult: Sendable, Equatable {
    public let sourceURL: String
    public let r2ObjectKey: String
    public let contentType: String

    public init(sourceURL: String, r2ObjectKey: String, contentType: String) {
        self.sourceURL = sourceURL
        self.r2ObjectKey = r2ObjectKey
        self.contentType = contentType
    }
}
