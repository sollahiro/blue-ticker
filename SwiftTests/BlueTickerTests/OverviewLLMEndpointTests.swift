// Overview の OpenRouter キー解決。本番名は OPENROUTER_OVERVIEW_API_KEY。
// 現在の VM だけ OPENROUTER_MOCK_KEY があればそれを使う（.env.example には載せない）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct OverviewLLMEndpointTests {
    @Test func productionKeyNameIncludesOverviewFeature() {
        #expect(companyOverviewAPIKeyEnv == "OPENROUTER_OVERVIEW_API_KEY")
        #expect(companyOverviewModelEnv == "OPENROUTER_OVERVIEW_MODEL")
        #expect(companyOverviewBaseURLEnv == "OPENROUTER_OVERVIEW_BASE_URL")
        #expect(companyOverviewMockAPIKeyEnv == "OPENROUTER_MOCK_KEY")
    }

    @Test func usesMockKeyOnCurrentVM() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewMockAPIKeyEnv: "mock-key",
            ]))
        #expect(endpoint.apiKey == "mock-key")
    }

    @Test func mockKeyWinsOverFeatureKey() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewMockAPIKeyEnv: "mock-key",
                companyOverviewAPIKeyEnv: "overview-prod-key",
            ]))
        #expect(endpoint.apiKey == "mock-key")
    }

    @Test func featureKeyWorksWhenMockIsAbsent() throws {
        let endpoint = try #require(
            resolveOverviewLLMEndpoint([
                companyOverviewAPIKeyEnv: "overview-prod-key",
            ]))
        #expect(endpoint.apiKey == "overview-prod-key")
    }

    @Test func genericOpenRouterApiKeyIsNotRead() {
        #expect(
            resolveOverviewLLMEndpoint([
                "OPENROUTER_API_KEY": "generic-key",
            ]) == nil)
    }

    @Test func missingKeysDisablesOverview() {
        #expect(resolveOverviewLLMEndpoint([:]) == nil)
        #expect(
            resolveOverviewLLMEndpoint([
                companyOverviewMockAPIKeyEnv: "",
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
        #expect(endpoint.maxTokens == 200)
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
