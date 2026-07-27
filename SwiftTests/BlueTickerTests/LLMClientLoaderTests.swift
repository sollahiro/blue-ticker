// LLMClientLoader / Server 側 resolveXaiEndpoint の軸別キー解決を検証する。
// プロセス環境を一時的に差し替えるため、並列実行で他テストと干渉しないよう
// `.serialized` で直列化する。

import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@testable import BlueTickerCore

@Suite(.serialized) struct LLMClientLoaderTests {

    private func withEnv(_ values: [String: String?], _ body: () throws -> Void) rethrows {
        let keys = [
            "XAI_API_KEY", "XAI_MODEL", "XAI_BASE_URL",
            "XAI_BUSINESS_API_KEY", "XAI_BUSINESS_MODEL", "XAI_BUSINESS_BASE_URL",
            "XAI_GEOGRAPHY_API_KEY", "XAI_GEOGRAPHY_MODEL", "XAI_GEOGRAPHY_BASE_URL",
        ]
        var previous: [String: String?] = [:]
        for key in keys {
            previous[key] = getenv(key).map { String(cString: $0) }
            unsetenv(key)
        }
        defer {
            for key in keys {
                if let restored = previous[key], let restored {
                    setenv(key, restored, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        for (key, value) in values {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        try body()
    }

    @Test func businessPrefersXaiBusinessOverLegacy() throws {
        try withEnv([
            "XAI_BUSINESS_API_KEY": "biz-key",
            "XAI_BUSINESS_MODEL": "biz-model",
            "XAI_BUSINESS_BASE_URL": "https://biz.example/",
            "XAI_API_KEY": "legacy-key",
            "XAI_MODEL": "legacy-model",
            "XAI_BASE_URL": "https://legacy.example/",
        ]) {
            let endpoint = try #require(LLMClientLoader.resolveEndpoint(axis: .business))
            #expect(endpoint.apiKey == "biz-key")
            #expect(endpoint.model == "biz-model")
            #expect(endpoint.baseURL == "https://biz.example/")

            let server = try #require(resolveXaiEndpoint(axis: .business))
            #expect(server.apiKey == "biz-key")
            #expect(server.model == "biz-model")
        }
    }

    @Test func businessFallsBackToLegacyXai() throws {
        try withEnv([
            "XAI_API_KEY": "legacy-key",
            "XAI_MODEL": "legacy-model",
        ]) {
            let endpoint = try #require(LLMClientLoader.resolveEndpoint(axis: .business))
            #expect(endpoint.apiKey == "legacy-key")
            #expect(endpoint.model == "legacy-model")
            #expect(endpoint.baseURL == Api.xaiBaseURL)

            let server = try #require(resolveXaiEndpoint(axis: .business))
            #expect(server.apiKey == "legacy-key")
        }
    }

    @Test func geographyUsesDedicatedKeysOnly() throws {
        try withEnv([
            "XAI_GEOGRAPHY_API_KEY": "geo-key",
            "XAI_GEOGRAPHY_MODEL": "geo-model",
            "XAI_API_KEY": "legacy-key",
            "XAI_MODEL": "legacy-model",
        ]) {
            let endpoint = try #require(LLMClientLoader.resolveEndpoint(axis: .geography))
            #expect(endpoint.apiKey == "geo-key")
            #expect(endpoint.model == "geo-model")

            let server = try #require(resolveXaiEndpoint(axis: .geography))
            #expect(server.apiKey == "geo-key")
        }
    }

    @Test func geographyDoesNotFallBackToLegacyXai() throws {
        try withEnv([
            "XAI_API_KEY": "legacy-key",
            "XAI_MODEL": "legacy-model",
        ]) {
            #expect(LLMClientLoader.resolveEndpoint(axis: .geography) == nil)
            #expect(resolveXaiEndpoint(axis: .geography) == nil)
        }
    }
}
