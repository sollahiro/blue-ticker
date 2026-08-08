// Cloudflare R2（S3互換オブジェクトストレージ）へのPUTアップロードクライアント。
// 署名は SigV4Signer（AWS Signature Version 4）に委譲する。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `BltServerContext.extractAndUploadCompanyIcon`（Server ファサード）が公開シグネチャで受け取るため
/// public（呼び出し元 BltServerCore ingest が環境変数から解決して渡す）。
public struct R2Config: Sendable {
    let accountID: String
    let accessKeyID: String
    let secretAccessKey: String
    let bucket: String
    let publicBaseURL: String

    public init(
        accountID: String, accessKeyID: String, secretAccessKey: String, bucket: String,
        publicBaseURL: String
    ) {
        self.accountID = accountID
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.bucket = bucket
        self.publicBaseURL = publicBaseURL
    }

    /// `BLT_R2_ACCOUNT_ID` / `BLT_R2_ACCESS_KEY_ID` / `BLT_R2_SECRET_ACCESS_KEY` /
    /// `BLT_R2_BUCKET` / `BLT_R2_PUBLIC_BASE_URL` から解決する。いずれか欠落時は nil。
    public static func resolveFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> R2Config? {
        guard let accountID = nonEmpty(environment["BLT_R2_ACCOUNT_ID"]),
            let accessKeyID = nonEmpty(environment["BLT_R2_ACCESS_KEY_ID"]),
            let secretAccessKey = nonEmpty(environment["BLT_R2_SECRET_ACCESS_KEY"]),
            let bucket = nonEmpty(environment["BLT_R2_BUCKET"]),
            let publicBaseURL = nonEmpty(environment["BLT_R2_PUBLIC_BASE_URL"])
        else { return nil }
        return R2Config(
            accountID: accountID, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            bucket: bucket, publicBaseURL: publicBaseURL
        )
    }

    /// 署名対象・PUT先となる S3 互換エンドポイントのホスト名。
    var endpointHost: String { "\(accountID).r2.cloudflarestorage.com" }

    /// アップロード後にクライアントへ返す公開URL（カスタムドメイン等、実値は `publicBaseURL` に委ねる）。
    public func publicURL(forKey key: String) -> String {
        buildR2PublicURL(baseURL: publicBaseURL, key: key)
    }
}

/// R2公開URLの組み立てのみを担う軽量設定（read経路専用）。`R2Config` と異なり、アップロードに
/// 必要な秘密鍵（account_id・access_key_id・secret_access_key・bucket）を要求しない。
/// アップロードを一切行わない配信プロセス（REST read）に秘密鍵を渡す最小権限違反を避けるため
/// （監査レビューで指摘）。
public struct R2PublicURLConfig: Sendable {
    let publicBaseURL: String

    public init(publicBaseURL: String) {
        self.publicBaseURL = publicBaseURL
    }

    /// `BLT_R2_PUBLIC_BASE_URL` のみから解決する。未設定時は nil。
    public static func resolveFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> R2PublicURLConfig? {
        guard let publicBaseURL = nonEmpty(environment["BLT_R2_PUBLIC_BASE_URL"]) else { return nil }
        return R2PublicURLConfig(publicBaseURL: publicBaseURL)
    }

    public func publicURL(forKey key: String) -> String {
        buildR2PublicURL(baseURL: publicBaseURL, key: key)
    }
}

private func buildR2PublicURL(baseURL: String, key: String) -> String {
    "\(baseURL)/\(key)"
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

enum R2Client {

    private static let requestTimeout: TimeInterval = 15
    private static let region = "auto"
    private static let service = "s3"

    private static let session: URLSession = {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: sessionConfig)
    }()

    enum UploadResult: Sendable, Equatable {
        case success
        case invalidURL
        case transportError(String)
        case httpStatus(Int, bodySnippet: String)
    }

    /// `data` を `key`（バケット内オブジェクトキー、先頭 `/` 無し）として PUT する。
    static func upload(_ data: Data, key: String, contentType: String, config: R2Config) async -> UploadResult {
        let path = "/\(config.bucket)/\(key)"
        guard let url = URL(string: "https://\(config.endpointHost)\(SigV4Signer.uriEncodePath(path))")
        else { return .invalidURL }

        let signed = SigV4Signer.sign(
            method: "PUT", host: config.endpointHost, path: path, contentType: contentType, payload: data,
            accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: region, service: service
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(signed.amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(signed.payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")

        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transportError("non-HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                let snippet = String(data: body.prefix(300), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                return .httpStatus(http.statusCode, bodySnippet: snippet)
            }
            return .success
        } catch {
            return .transportError(String(describing: error))
        }
    }
}
