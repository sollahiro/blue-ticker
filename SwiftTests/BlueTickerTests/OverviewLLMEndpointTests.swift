// Overview の OpenRouter キー解決。読むのは OPENROUTER_OVERVIEW_API_KEY のみ。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct OverviewLLMEndpointTests {
    @Test func productionKeyNameIncludesOverviewFeature() {
        #expect(companyOverviewAPIKeyEnv == "OPENROUTER_OVERVIEW_API_KEY")
        #expect(companyOverviewModelEnv == "OPENROUTER_OVERVIEW_MODEL")
        #expect(companyOverviewBaseURLEnv == "OPENROUTER_OVERVIEW_BASE_URL")
    }

    @Test func featureKeyWorks() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewAPIKeyEnv: "overview-prod-key",
            ]))
        #expect(endpoint.apiKey == "overview-prod-key")
    }

    @Test func mockAndGenericOpenRouterKeysAreNotRead() {
        #expect(
            resolveOverviewLLMEndpoint([
                "OPENROUTER_MOCK_KEY": "mock-key",
            ]) == nil)
        #expect(
            resolveOverviewLLMEndpoint([
                "OPENROUTER_API_KEY": "generic-key",
            ]) == nil)
        let endpoint = resolveOverviewLLMEndpoint([
            "OPENROUTER_MOCK_KEY": "mock-key",
            companyOverviewAPIKeyEnv: "overview-prod-key",
        ])
        #expect(endpoint?.apiKey == "overview-prod-key")
    }

    @Test func missingKeysDisablesOverview() {
        #expect(resolveOverviewLLMEndpoint([:]) == nil)
        #expect(
            resolveOverviewLLMEndpoint([
                companyOverviewAPIKeyEnv: "  ",
            ]) == nil)
    }

    @Test func readsFeatureModelAndBaseURL() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewAPIKeyEnv: "overview-prod-key",
                companyOverviewModelEnv: "google/gemini-2.5-flash",
                companyOverviewBaseURLEnv: "https://openrouter.example/v1",
            ]))
        #expect(endpoint.apiKey == "overview-prod-key")
        #expect(endpoint.model == "google/gemini-2.5-flash")
        #expect(endpoint.baseURL == "https://openrouter.example/v1")
        #expect(endpoint.provider == .openrouter)
        #expect(endpoint.maxTokens == 1024)
    }

    @Test func defaultsModelAndBaseURL() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([companyOverviewAPIKeyEnv: "overview-prod-key"]))
        #expect(endpoint.model == companyOverviewDefaultModel)
        #expect(endpoint.baseURL == Api.openrouterBaseURL)
    }

    @Test func breakdownProviderEnvDoesNotAcceptOpenRouter() {
        #expect(LLMProvider.fromEnv(["LLM_PROVIDER": "openrouter"]) == nil)
    }
}
