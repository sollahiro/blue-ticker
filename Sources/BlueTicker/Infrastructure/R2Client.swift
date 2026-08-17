// Cloudflare R2（S3互換オブジェクトストレージ）の PUT / GET クライアント。
// 署名は SigV4Signer（AWS Signature Version 4）に委譲する。
// 会社アイコンは公開 URL 付き `R2Config`、生 XBRL ZIP は私有の `R2StorageConfig`（公開 URL 不要）。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 生 XBRL ZIP など、公開 URL を持たない R2 オブジェクト操作用の資格情報。
/// アカウントと鍵はアイコンと共有し、バケットだけ分ける（公開カスタムドメイン付きの
/// アイコン用バケットへ原本 ZIP を置かないため）。
struct R2StorageConfig: Sendable {
    let accountID: String
    let accessKeyID: String
    let secretAccessKey: String
    let bucket: String

    var endpointHost: String { "\(accountID).r2.cloudflarestorage.com" }

    /// 会社アイコン用。`BLT_R2_ICONS_BUCKET`、無ければ旧名 `BLT_R2_BUCKET`。
    /// アカウント／鍵が欠けるかバケット未設定なら nil。
    static func resolveIconsFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> R2StorageConfig? {
        let bucket = nonEmpty(environment["BLT_R2_ICONS_BUCKET"])
            ?? nonEmpty(environment["BLT_R2_BUCKET"])
        guard let bucket else { return nil }
        return resolve(environment, bucket: bucket)
    }

    /// 生 XBRL ZIP 用。`BLT_R2_XBRL_BUCKET` のみ（アイコン用バケットへフォールバックしない）。
    static func resolveXbrlFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> R2StorageConfig? {
        guard let bucket = nonEmpty(environment["BLT_R2_XBRL_BUCKET"]) else { return nil }
        return resolve(environment, bucket: bucket)
    }

    private static func resolve(
        _ environment: [String: String], bucket: String
    ) -> R2StorageConfig? {
        guard let accountID = nonEmpty(environment["BLT_R2_ACCOUNT_ID"]),
            let accessKeyID = nonEmpty(environment["BLT_R2_ACCESS_KEY_ID"]),
            let secretAccessKey = nonEmpty(environment["BLT_R2_SECRET_ACCESS_KEY"])
        else { return nil }
        return R2StorageConfig(
            accountID: accountID, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            bucket: bucket
        )
    }
}

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
    /// `BLT_R2_ICONS_BUCKET`（無ければ旧 `BLT_R2_BUCKET`）/ `BLT_R2_PUBLIC_BASE_URL`
    /// から解決する。いずれか欠落時は nil。
    public static func resolveFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> R2Config? {
        guard let storage = R2StorageConfig.resolveIconsFromEnvironment(environment),
            let publicBaseURL = nonEmpty(environment["BLT_R2_PUBLIC_BASE_URL"])
        else { return nil }
        return R2Config(
            accountID: storage.accountID, accessKeyID: storage.accessKeyID,
            secretAccessKey: storage.secretAccessKey, bucket: storage.bucket,
            publicBaseURL: publicBaseURL
        )
    }

    var storage: R2StorageConfig {
        R2StorageConfig(
            accountID: accountID, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            bucket: bucket
        )
    }

    /// 署名対象・PUT先となる S3 互換エンドポイントのホスト名。
    var endpointHost: String { storage.endpointHost }

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

/// 生 XBRL ZIP のオブジェクトキー。docID は英数字のみ（パス区切りの混入を拒否）。
func xbrlR2ObjectKey(docID: String) -> String? {
    guard !docID.isEmpty, docID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return "\(Api.xbrlR2KeyPrefix)/\(docID).zip"
}

/// ingest が生 XBRL ZIP を読む／書くための最小面。本番は `R2XbrlObjectStore`、テストはメモリ実装。
protocol XbrlObjectStoring: Sendable {
    func getObject(key: String) async -> Data?
    func putObject(_ data: Data, key: String, contentType: String) async -> Bool
}

struct R2XbrlObjectStore: XbrlObjectStoring {
    let config: R2StorageConfig

    func getObject(key: String) async -> Data? {
        switch await R2Client.download(key: key, config: config) {
        case .success(let data):
            return data
        case .notFound:
            return nil
        case .invalidURL:
            printError("R2 XBRL GET 失敗 key=\(key) invalid_url\n")
            return nil
        case .transportError(let message):
            printError("R2 XBRL GET 失敗 key=\(key) \(message)\n")
            return nil
        case .httpStatus(let status, let snippet):
            printError("R2 XBRL GET 失敗 key=\(key) http=\(status) \(snippet)\n")
            return nil
        }
    }

    func putObject(_ data: Data, key: String, contentType: String) async -> Bool {
        switch await R2Client.upload(
            data, key: key, contentType: contentType, config: config,
            timeout: Api.r2XbrlTransferTimeoutSeconds
        ) {
        case .success:
            return true
        case .invalidURL:
            printError("R2 XBRL PUT 失敗 key=\(key) invalid_url\n")
            return false
        case .transportError(let message):
            printError("R2 XBRL PUT 失敗 key=\(key) \(message)\n")
            return false
        case .httpStatus(let status, let snippet):
            printError("R2 XBRL PUT 失敗 key=\(key) http=\(status) \(snippet)\n")
            return false
        }
    }
}

enum R2Client {

    private static let region = "auto"
    private static let service = "s3"

    private static let session: URLSession = {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = Api.r2XbrlTransferTimeoutSeconds
        sessionConfig.timeoutIntervalForResource = Api.r2XbrlTransferTimeoutSeconds
        return URLSession(configuration: sessionConfig)
    }()

    enum UploadResult: Sendable, Equatable {
        case success
        case invalidURL
        case transportError(String)
        case httpStatus(Int, bodySnippet: String)
    }

    enum DownloadResult: Sendable, Equatable {
        case success(Data)
        case notFound
        case invalidURL
        case transportError(String)
        case httpStatus(Int, bodySnippet: String)
    }

    /// `data` を `key`（バケット内オブジェクトキー、先頭 `/` 無し）として PUT する。
    static func upload(
        _ data: Data, key: String, contentType: String, config: R2Config
    ) async -> UploadResult {
        await upload(
            data, key: key, contentType: contentType, config: config.storage,
            timeout: Api.r2IconUploadTimeoutSeconds
        )
    }

    static func upload(
        _ data: Data, key: String, contentType: String, config: R2StorageConfig,
        timeout: TimeInterval
    ) async -> UploadResult {
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
        request.timeoutInterval = timeout
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
                return .httpStatus(http.statusCode, bodySnippet: httpBodySnippet(body))
            }
            return .success
        } catch {
            return .transportError(String(describing: error))
        }
    }

    /// `key` のオブジェクトを GET する。404 は `.notFound`（キャッシュミスとして EDINET へ進む）。
    static func download(
        key: String, config: R2StorageConfig,
        timeout: TimeInterval = Api.r2XbrlTransferTimeoutSeconds
    ) async -> DownloadResult {
        let path = "/\(config.bucket)/\(key)"
        guard let url = URL(string: "https://\(config.endpointHost)\(SigV4Signer.uriEncodePath(path))")
        else { return .invalidURL }

        let signed = SigV4Signer.sign(
            method: "GET", host: config.endpointHost, path: path, contentType: nil, payload: Data(),
            accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
            region: region, service: service
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(signed.amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(signed.payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")

        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transportError("non-HTTP response")
            }
            if http.statusCode == 404 { return .notFound }
            guard (200...299).contains(http.statusCode) else {
                return .httpStatus(http.statusCode, bodySnippet: httpBodySnippet(body))
            }
            return .success(body)
        } catch {
            return .transportError(String(describing: error))
        }
    }
}

private func httpBodySnippet(_ body: Data) -> String {
    String(data: body.prefix(300), encoding: .utf8)?
        .replacingOccurrences(of: "\n", with: " ") ?? ""
}
