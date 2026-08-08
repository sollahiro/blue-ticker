// Cloudflare R2（S3互換オブジェクトストレージ）へのPUTアップロードクライアント。
// 署名は SigV4Signer（AWS Signature Version 4）に委譲する。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct R2Config: Sendable {
    let accountID: String
    let accessKeyID: String
    let secretAccessKey: String
    let bucket: String
    let publicBaseURL: String

    /// `BLT_R2_ACCOUNT_ID` / `BLT_R2_ACCESS_KEY_ID` / `BLT_R2_SECRET_ACCESS_KEY` /
    /// `BLT_R2_BUCKET` / `BLT_R2_PUBLIC_BASE_URL` から解決する。いずれか欠落時は nil。
    static func resolveFromEnvironment(
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
    func publicURL(forKey key: String) -> String {
        "\(publicBaseURL)/\(key)"
    }
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

    /// `data` を `key`（バケット内オブジェクトキー、先頭 `/` 無し）として PUT する。成功時 true。
    static func upload(_ data: Data, key: String, contentType: String, config: R2Config) async -> Bool {
        let path = "/\(config.bucket)/\(key)"
        guard let url = URL(string: "https://\(config.endpointHost)\(SigV4Signer.uriEncodePath(path))")
        else { return false }

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

        guard let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return false }
        return true
    }
}
