import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BlueTickerCore

private struct StubEsefHTTPTransport: EsefHTTPTransport {
    var handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

@Suite struct EsefSearchTests {

    @Test func normalizeRemovesWhitespaceAndCase() {
        #expect(EsefSearchNormalization.normalize("Atlas Copco") == "ATLASCOPCO")
        #expect(EsefSearchNormalization.looksLikeIdentifier("213800T8PC8Q4FYJZR07"))
        #expect(EsefSearchNormalization.looksLikeFxoId("213800T8PC8Q4FYJZR07-2024-12-31-ESEF-SE-1"))
        #expect(!EsefSearchNormalization.looksLikeFxoId("213800T8PC8Q4FYJZR07"))
    }

    @Test func entityIndexSearchMatchesIdentifierAndNameSubstring() async {
        let index = EsefEntityIndexStore()
        await index.replaceAll([
            EsefEntity(identifier: "213800T8PC8Q4FYJZR07", name: "ATLAS COPCO AKTIEBOLAG"),
            EsefEntity(identifier: "OTHERLEI00000000001", name: "Envipco Holding N.V."),
        ])

        let byLei = await index.search("213800T8PC8Q4FYJZR07")
        #expect(byLei.count == 1)
        #expect(byLei.first?.name == "ATLAS COPCO AKTIEBOLAG")

        let byName = await index.search("atlas")
        #expect(byName.count == 1)
        #expect(byName.first?.identifier == "213800T8PC8Q4FYJZR07")

        let byPartial = await index.search("envipco")
        #expect(byPartial.count == 1)
    }

    @Test func searchServiceUsesSeededIndexWithoutNetwork() async throws {
        let transport = StubEsefHTTPTransport { _ in
            Issue.record("network should not be called for seeded name search")
            throw EsefFilingsAPIError.httpStatus(500)
        }
        let client = EsefFilingsAPIClient(transport: transport)
        let tmp = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = EsefSearchService(client: client, cacheDir: tmp)
        await service.seedIndex([
            EsefEntity(identifier: "213800T8PC8Q4FYJZR07", name: "ATLAS COPCO AKTIEBOLAG"),
        ])

        let hits = try await service.search("copco", limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].identifier == "213800T8PC8Q4FYJZR07")
        #expect(hits[0].region == "EU")
        #expect(hits[0].source == "ESEF")
        #expect(hits[0].matchedFiling == nil)
    }

    @Test func searchServiceResolvesFxoIdViaClient() async throws {
        let transport = StubEsefHTTPTransport { request in
            let url = request.url!.absoluteString
            #expect(url.contains("/filings"))
            #expect(url.contains("fxo_id") || url.contains("fxo%5Fid") || url.contains("filter"))
            let body: [String: Any] = [
                "data": [[
                    "type": "filing",
                    "id": "1",
                    "attributes": [
                        "fxo_id": "213800T8PC8Q4FYJZR07-2024-12-31-ESEF-SE-1",
                        "country": "SE",
                        "period_end": "2024-12-31",
                        "json_url": "/213800T8PC8Q4FYJZR07/2024-12-31/ESEF/SE/1/atla.json",
                        "package_url": nil,
                        "report_url": "/213800T8PC8Q4FYJZR07/2024-12-31/ESEF/SE/1/atla.html",
                    ],
                    "relationships": [
                        "entity": ["data": ["type": "entity", "id": "2308"]],
                    ],
                ]],
                "included": [[
                    "type": "entity",
                    "id": "2308",
                    "attributes": [
                        "name": "ATLAS COPCO AKTIEBOLAG",
                        "identifier": "213800T8PC8Q4FYJZR07",
                    ],
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let client = EsefFilingsAPIClient(transport: transport)
        let tmp = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = EsefSearchService(client: client, cacheDir: tmp)

        let hits = try await service.search("213800T8PC8Q4FYJZR07-2024-12-31-ESEF-SE-1")
        #expect(hits.count == 1)
        #expect(hits[0].name == "ATLAS COPCO AKTIEBOLAG")
        #expect(hits[0].matchedFiling?.country == "SE")
        #expect(hits[0].matchedFiling?.periodEnd == "2024-12-31")
        #expect(hits[0].matchedFiling?.jsonURL?.contains("atla.json") == true)
    }

    @Test func searchServiceLiveIdentifierFallback() async throws {
        let transport = StubEsefHTTPTransport { request in
            let body: [String: Any] = [
                "meta": ["count": 1],
                "data": [[
                    "type": "entity",
                    "id": "2308",
                    "attributes": [
                        "name": "ATLAS COPCO AKTIEBOLAG",
                        "identifier": "213800T8PC8Q4FYJZR07",
                    ],
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let client = EsefFilingsAPIClient(transport: transport)
        let tmp = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = EsefSearchService(client: client, cacheDir: tmp)

        let hits = try await service.search("213800T8PC8Q4FYJZR07")
        #expect(hits.count == 1)
        #expect(hits[0].identifier == "213800T8PC8Q4FYJZR07")
    }

    @Test func emptyIndexNameSearchThrows() async throws {
        let transport = StubEsefHTTPTransport { request in
            // exact name live miss
            let body: [String: Any] = ["meta": ["count": 0], "data": [] as [[String: Any]]]
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let client = EsefFilingsAPIClient(transport: transport)
        let tmp = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = EsefSearchService(client: client, cacheDir: tmp)

        do {
            _ = try await service.search("Atlas")
            Issue.record("expected emptyIndex")
        } catch let error as EsefSearchError {
            #expect(error == .emptyIndex)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func refreshIndexPersistsSnapshot() async throws {
        let transport = StubEsefHTTPTransport { request in
            let url = request.url!.absoluteString
            #expect(url.contains("/entities"))
            let body: [String: Any] = [
                "meta": ["count": 2],
                "data": [
                    [
                        "type": "entity",
                        "id": "1",
                        "attributes": ["name": "A Co", "identifier": "AAAAAAAAAAAAAAA001"],
                    ],
                    [
                        "type": "entity",
                        "id": "2",
                        "attributes": ["name": "B Co", "identifier": "BBBBBBBBBBBBBBB002"],
                    ],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let client = EsefFilingsAPIClient(transport: transport)
        let tmp = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = EsefSearchService(client: client, cacheDir: tmp)

        let count = try await service.refreshIndex(pageSize: 200)
        #expect(count == 2)
        #expect(await service.indexCount() == 2)
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("entity_index.json").path))

        let hits = try await service.search("B Co")
        #expect(hits.first?.identifier == "BBBBBBBBBBBBBBB002")
    }
}
