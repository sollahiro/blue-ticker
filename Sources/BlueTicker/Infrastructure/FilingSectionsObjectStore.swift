// 有報セクション本文（FilingSectionsPayload）を R2 に置く最小面。
// company_filing_sections の行は索引（doc_id / code / 版 / r2_key）として DB に残し、本文だけを R2 へ移す。
// バケットは生 XBRL ZIP と同じ私有バケット（`BLT_R2_XBRL_BUCKET`）で、キー接頭辞だけ分ける。
// 資格情報は `BLT_R2_ACCOUNT_ID` / `BLT_R2_ACCESS_KEY_ID` / `BLT_R2_SECRET_ACCESS_KEY`。
// 未設定なら nil（呼び出し側は DB 格納へフォールバックする）。

import Foundation

public enum FilingSectionsObjectStoreError: Error, Sendable, Equatable {
    case invalidKey(String)
    case unavailable(String)
}

/// 本文の取得・格納。`get` は未格納（404）を nil で返し、それ以外の失敗は throw する。
public protocol FilingSectionsObjectStoring: Sendable {
    func get(key: String) async throws -> FilingSectionsPayload?
    func put(_ payload: FilingSectionsPayload, key: String) async throws
}

/// 書類（EDINET docID）ごとのオブジェクトキー。docID は英数字のみ（パス区切りの混入を拒否）。
public func filingSectionsObjectKey(docID: String) -> String? {
    guard !docID.isEmpty, docID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return "\(Api.filingSectionsR2KeyPrefix)/\(docID).json"
}

public struct R2FilingSectionsStore: FilingSectionsObjectStoring {
    let config: R2StorageConfig

    /// `BLT_R2_*`（XBRL と同じ資格情報とバケット）から解決する。未設定時は nil。
    public static func resolveFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> R2FilingSectionsStore? {
        R2StorageConfig.resolveXbrlFromEnvironment(environment).map { R2FilingSectionsStore(config: $0) }
    }

    public func get(key: String) async throws -> FilingSectionsPayload? {
        switch await R2Client.download(key: key, config: config) {
        case .success(let data):
            do {
                return try JSONDecoder().decode(FilingSectionsPayload.self, from: data)
            } catch {
                throw FilingSectionsObjectStoreError.unavailable("decode key=\(key)")
            }
        case .notFound:
            return nil
        case .invalidURL:
            throw FilingSectionsObjectStoreError.invalidKey(key)
        case .transportError(let message):
            throw FilingSectionsObjectStoreError.unavailable("GET key=\(key) \(message)")
        case .httpStatus(let status, _):
            throw FilingSectionsObjectStoreError.unavailable("GET key=\(key) http=\(status)")
        }
    }

    public func put(_ payload: FilingSectionsPayload, key: String) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        switch await R2Client.upload(
            data, key: key, contentType: "application/json", config: config,
            timeout: Api.r2XbrlTransferTimeoutSeconds
        ) {
        case .success:
            return
        case .invalidURL:
            throw FilingSectionsObjectStoreError.invalidKey(key)
        case .transportError(let message):
            throw FilingSectionsObjectStoreError.unavailable("PUT key=\(key) \(message)")
        case .httpStatus(let status, _):
            throw FilingSectionsObjectStoreError.unavailable("PUT key=\(key) http=\(status)")
        }
    }
}
