// Overview の OpenRouter キー解決。今回は mock キーを流用し、本番名は OPENROUTER_API_KEY。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct OverviewLLMEndpointTests {
    @Test func usesMockKeyForThisImplementation() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewMockAPIKeyEnv: "mock-key",
            ]))
        #expect(endpoint.apiKey == "mock-key")
        #expect(companyOverviewMockAPIKeyEnv == "OPENROUTER_MOCK_KEY")
        #expect(companyOverviewAPIKeyEnv == "OPENROUTER_API_KEY")
    }

    @Test func mockKeyWinsOverProductionName() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewMockAPIKeyEnv: "mock-key",
                companyOverviewAPIKeyEnv: "prod-key",
            ]))
        #expect(endpoint.apiKey == "mock-key")
    }

    @Test func productionNameWorksWhenMockIsAbsent() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewAPIKeyEnv: "prod-key",
            ]))
        #expect(endpoint.apiKey == "prod-key")
    }

    @Test func missingBothKeysDisablesOverview() {
        #expect(resolveOverviewLLMEndpoint([:]) == nil)
        #expect(
            resolveOverviewLLMEndpoint([
                companyOverviewMockAPIKeyEnv: "",
                companyOverviewAPIKeyEnv: "  ",
            ]) == nil)
    }

    @Test func readsKeyModelAndBaseURL() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewMockAPIKeyEnv: "mock-key",
                "OPENROUTER_MODEL": "google/gemini-2.5-flash",
                "OPENROUTER_BASE_URL": "https://openrouter.example/v1",
            ]))
        #expect(endpoint.apiKey == "mock-key")
        #expect(endpoint.model == "google/gemini-2.5-flash")
        #expect(endpoint.baseURL == "https://openrouter.example/v1")
        #expect(endpoint.provider == .openrouter)
        #expect(endpoint.maxTokens == 200)
    }

    @Test func defaultsModelAndBaseURL() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([companyOverviewMockAPIKeyEnv: "mock-key"]))
        #expect(endpoint.model == companyOverviewDefaultModel)
        #expect(endpoint.baseURL == Api.openrouterBaseURL)
    }

    @Test func breakdownProviderEnvDoesNotAcceptOpenRouter() {
        #expect(LLMProvider.fromEnv(["LLM_PROVIDER": "openrouter"]) == nil)
    }
}
