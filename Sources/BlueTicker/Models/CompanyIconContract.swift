// 会社アイコン取り込み（EDINET電子公告URL→favicon→R2）の格納用バージョン定数。
// company_icons.cache_version（Neon）に埋め込む。blueTickerVersion 非連動（fin-v2 / facts-v1 と
// 同思想）。CorporateWebsiteExtractor の抽出ロジック、または FaviconFetcher の取得・判定ロジックを
// 変更したときのみバンプする。

import Foundation

/// Neon 会社アイコン取り込み キャッシュ（company_icons.cache_version）の抽出バージョン。
/// v1 → v2: Pronexus 電子公告 16 社を公式 origin へ決め打ち。WordPress 既定ファビコンを棄てて
/// HTML `<link rel="icon">` を先に取る。
public let companyIconsCacheVersion = "icons-v2"

/// 会社アイコン取り込み（1書類分）の抽出・アップロード結果。R2への格納が完了した状態のみを表す
/// （途中失敗は `CompanyIconExtractFailure`。`BltServerContext.extractAndUploadCompanyIcon` が返す）。
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

/// 会社アイコン取り込みの途中失敗。どの段で止まったかをログに出すための戻り値パターン。
public enum CompanyIconExtractFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case downloadFailed
    case urlExtractFailed(method: String)
    case faviconFetchFailed(origin: String)
    case r2UploadFailed(detail: String)

    public var description: String {
        switch self {
        case .downloadFailed:
            return "download_failed"
        case .urlExtractFailed(let method):
            return "url_extract_failed(method=\(method))"
        case .faviconFetchFailed(let origin):
            return "favicon_fetch_failed(origin=\(origin))"
        case .r2UploadFailed(let detail):
            return "r2_upload_failed(\(detail))"
        }
    }
}

