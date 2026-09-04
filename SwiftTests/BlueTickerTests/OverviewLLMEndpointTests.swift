// Overview の OpenRouter キー解決。mock キーは使わない。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct OverviewLLMEndpointTests {
    @Test func requiresOpenRouterApiKeyAndIgnoresMockKey() {
        #expect(
            resolveOverviewLLMEndpoint([
                "OPENROUTER_MOCK_KEY": "mock-only",
            ]) == nil)
        #expect(
            resolveOverviewLLMEndpoint([
                "OPENROUTER_API_KEY": "",
                "OPENROUTER_MOCK_KEY": "mock-only",
            ]) == nil)
    }

    @Test func readsKeyModelAndBaseURL() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                "OPENROUTER_API_KEY": "real-key",
                "OPENROUTER_MODEL": "google/gemini-2.5-flash",
                "OPENROUTER_BASE_URL": "https://openrouter.example/v1",
            ]))
        #expect(endpoint.apiKey == "real-key")
        #expect(endpoint.model == "google/gemini-2.5-flash")
        #expect(endpoint.baseURL == "https://openrouter.example/v1")
        #expect(endpoint.provider == .openrouter)
        #expect(endpoint.maxTokens == 200)
    }

    @Test func defaultsModelAndBaseURL() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint(["OPENROUTER_API_KEY": "real-key"]))
        #expect(endpoint.model == companyOverviewDefaultModel)
        #expect(endpoint.baseURL == Api.openrouterBaseURL)
    }

    @Test func breakdownProviderEnvDoesNotAcceptOpenRouter() {
        #expect(LLMProvider.fromEnv(["LLM_PROVIDER": "openrouter"]) == nil)
    }
}
