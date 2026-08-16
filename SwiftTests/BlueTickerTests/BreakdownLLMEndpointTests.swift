// resolveBreakdownLLMEndpoint の軸別キー解決を検証する。
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

@Suite(.serialized) struct BreakdownLLMEndpointTests {

    private func withEnv(_ values: [String: String?], _ body: () throws -> Void) rethrows {
        let keys = [
            "LLM_PROVIDER",
            "XAI_API_KEY", "XAI_MODEL", "XAI_BASE_URL",
            "XAI_BUSINESS_API_KEY", "XAI_BUSINESS_MODEL", "XAI_BUSINESS_BASE_URL",
            "XAI_GEOGRAPHY_API_KEY", "XAI_GEOGRAPHY_MODEL", "XAI_GEOGRAPHY_BASE_URL",
            "OPENAI_BUSINESS_API_KEY", "OPENAI_BUSINESS_MODEL", "OPENAI_BUSINESS_BASE_URL",
            "OPENAI_GEOGRAPHY_API_KEY", "OPENAI_GEOGRAPHY_MODEL", "OPENAI_GEOGRAPHY_BASE_URL",
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
            let endpoint = try #require(resolveBreakdownLLMEndpoint(axis: .business))
            #expect(endpoint.apiKey == "biz-key")
            #expect(endpoint.model == "biz-model")
            #expect(endpoint.baseURL == "https://biz.example/")
        }
    }

    @Test func businessFallsBackToLegacyXai() throws {
        try withEnv([
            "XAI_API_KEY": "legacy-key",
            "XAI_MODEL": "legacy-model",
        ]) {
            let endpoint = try #require(resolveBreakdownLLMEndpoint(axis: .business))
            #expect(endpoint.apiKey == "legacy-key")
            #expect(endpoint.model == "legacy-model")
            #expect(endpoint.baseURL == Api.xaiBaseURL)
        }
    }

    @Test func geographyUsesDedicatedKeysOnly() throws {
        try withEnv([
            "XAI_GEOGRAPHY_API_KEY": "geo-key",
            "XAI_GEOGRAPHY_MODEL": "geo-model",
            "XAI_API_KEY": "legacy-key",
            "XAI_MODEL": "legacy-model",
        ]) {
            let endpoint = try #require(resolveBreakdownLLMEndpoint(axis: .geography))
            #expect(endpoint.apiKey == "geo-key")
            #expect(endpoint.model == "geo-model")
        }
    }

    @Test func geographyDoesNotFallBackToLegacyXai() {
        withEnv([
            "XAI_API_KEY": "legacy-key",
            "XAI_MODEL": "legacy-model",
        ]) {
            #expect(resolveBreakdownLLMEndpoint(axis: .geography) == nil)
        }
    }

    @Test func providerFromEnvDefaultsAndNormalizesValues() {
        #expect(LLMProvider.fromEnv([:]) == .xai)
        #expect(LLMProvider.fromEnv(["LLM_PROVIDER": "   "]) == .xai)
        #expect(LLMProvider.fromEnv(["LLM_PROVIDER": "grok"]) == .xai)
        #expect(LLMProvider.fromEnv(["LLM_PROVIDER": "OpEnAi"]) == .openai)
        #expect(LLMProvider.fromEnv(["LLM_PROVIDER": "anthropic"]) == nil)
    }

    @Test func openaiProviderReadsOpenAIKeysNotXai() throws {
        try withEnv([
            "LLM_PROVIDER": "openai",
            "OPENAI_BUSINESS_API_KEY": "openai-biz",
            "OPENAI_BUSINESS_MODEL": "fixture-openai-model",
            "OPENAI_GEOGRAPHY_API_KEY": "openai-geo",
            "OPENAI_GEOGRAPHY_MODEL": "fixture-openai-model",
            "XAI_BUSINESS_API_KEY": "xai-biz",
            "XAI_BUSINESS_MODEL": "grok-4.5",
            "XAI_GEOGRAPHY_API_KEY": "xai-geo",
            "XAI_GEOGRAPHY_MODEL": "grok-4.5",
        ]) {
            let business = try #require(resolveBreakdownLLMEndpoint(axis: .business))
            #expect(business.provider == .openai)
            #expect(business.apiKey == "openai-biz")
            #expect(business.model == "fixture-openai-model")
            #expect(business.baseURL == Api.openaiBaseURL)
            let geography = try #require(resolveBreakdownLLMEndpoint(axis: .geography))
            #expect(geography.apiKey == "openai-geo")
        }
    }

    @Test func xaiProviderReadsXaiKeysNotOpenAI() throws {
        try withEnv([
            "LLM_PROVIDER": "xai",
            "OPENAI_BUSINESS_API_KEY": "openai-biz",
            "OPENAI_BUSINESS_MODEL": "fixture-openai-model",
            "OPENAI_GEOGRAPHY_API_KEY": "openai-geo",
            "OPENAI_GEOGRAPHY_MODEL": "fixture-openai-model",
            "XAI_BUSINESS_API_KEY": "xai-biz",
            "XAI_BUSINESS_MODEL": "grok-4.5",
            "XAI_GEOGRAPHY_API_KEY": "xai-geo",
            "XAI_GEOGRAPHY_MODEL": "grok-4.5",
        ]) {
            let business = try #require(resolveBreakdownLLMEndpoint(axis: .business))
            #expect(business.provider == .xai)
            #expect(business.apiKey == "xai-biz")
            #expect(business.model == "grok-4.5")
            #expect(business.baseURL == Api.xaiBaseURL)
            let geography = try #require(resolveBreakdownLLMEndpoint(axis: .geography))
            #expect(geography.apiKey == "xai-geo")
        }
    }

    @Test func omittedProviderDefaultsToXai() throws {
        try withEnv([
            "XAI_BUSINESS_API_KEY": "biz-key",
            "XAI_BUSINESS_MODEL": "grok-4.5",
        ]) {
            let endpoint = try #require(resolveBreakdownLLMEndpoint(axis: .business))
            #expect(endpoint.provider == .xai)
            #expect(endpoint.baseURL == Api.xaiBaseURL)
        }
    }

    @Test func invalidProviderDoesNotResolve() {
        withEnv([
            "LLM_PROVIDER": "anthropic",
            "OPENAI_BUSINESS_API_KEY": "biz-key",
            "OPENAI_BUSINESS_MODEL": "fixture-openai-model",
        ]) {
            #expect(resolveBreakdownLLMEndpoint(axis: .business) == nil)
        }
    }

    @Test func openaiAxisBaseURLOverridesProviderDefault() throws {
        try withEnv([
            "LLM_PROVIDER": "openai",
            "OPENAI_BUSINESS_API_KEY": "biz-key",
            "OPENAI_BUSINESS_MODEL": "fixture-openai-model",
            "OPENAI_BUSINESS_BASE_URL": "https://proxy.example/v1",
        ]) {
            let endpoint = try #require(resolveBreakdownLLMEndpoint(axis: .business))
            #expect(endpoint.provider == .openai)
            #expect(endpoint.baseURL == "https://proxy.example/v1")
        }
    }

    @Test func openaiDoesNotFallBackToXaiKeys() {
        withEnv([
            "LLM_PROVIDER": "openai",
            "XAI_BUSINESS_API_KEY": "xai-biz",
            "XAI_BUSINESS_MODEL": "grok-4.5",
        ]) {
            #expect(resolveBreakdownLLMEndpoint(axis: .business) == nil)
        }
    }
}
