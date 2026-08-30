// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳回帰（SPEC_ORACLE の L1 実行器）。
// 対象企業は各 @Test にハードコード。共有モックは RealXbrlBreakdownSupport.swift。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlBreakdownLiveLLMTests {

    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static var liveLLMAvailable: Bool {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["XAI_API_KEY"], !key.isEmpty,
              let model = env["XAI_MODEL"], !model.isEmpty
        else { return false }
        return true
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    private static func makeClient() throws -> ChatCompletionClient {
        let endpoint = try #require(resolveBreakdownLLMEndpoint(axis: .business))
        return ChatCompletionClient(endpoint: endpoint)
    }

    @Test(.enabled(
        if: liveLLMAvailable && cacheAvailable("S100XRPR"),
        "XAI_API_KEY/XAI_MODEL or XBRL cache S100XRPR not available"
    ))
    func bridgestoneLiveLLMReturnsTireAndOther() async throws {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XRPR"))
        let client = try Self.makeClient()
        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 4_429_452_000_000, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        #expect(snapshot?.needsReview == false)
        let labels = Set(snapshot?.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw) ?? [])
        #expect(labels.contains("タイヤ"))
        #expect(labels.contains("その他"))
        #expect(labels.count == 2)
        let notes = audit?.notes ?? ""
        #expect(notes.contains("化工品") || notes.contains("ソリューション") || notes.contains("多角化"))
    }

    @Test(.enabled(
        if: liveLLMAvailable && cacheAvailable("S100Y9T1"),
        "XAI_API_KEY/XAI_MODEL or XBRL cache S100Y9T1 not available"
    ))
    func densoLiveLLMReturnsBusinessSystems() async throws {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100Y9T1"))
        let client = try Self.makeClient()
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 7_539_975_000_000, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        #expect(snapshot?.needsReview == false)
        let labels = Set(snapshot?.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw) ?? [])
        #expect(labels.contains(where: { $0.contains("サーマル") }))
        #expect(labels.contains(where: { $0.contains("パワトレイン") }))
        #expect(labels.contains(where: { $0.contains("モビリティ") }))
    }

    @Test(.enabled(
        if: liveLLMAvailable && cacheAvailable("S100YH3M"),
        "XAI_API_KEY/XAI_MODEL or XBRL cache S100YH3M not available"
    ))
    func sumitomoLiveLLMReturnsProductRows() async throws {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YH3M"))
        let client = try Self.makeClient()
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 453_294_000_000, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(snapshot?.needsReview == false)
        let labels = snapshot?.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw).joined(separator: " ") ?? ""
        #expect(labels.contains("ラツーダ"))
        #expect(labels.contains("オルゴビクス") || labels.contains("ORGOVYX"))
    }
}

// MARK: - goodwill 軸（2026-08-12追加）

/// smoke 固定11社の goodwill 軸床（Step 1）。J-GAAP4社は resolved、残7社は segment dimension
/// タグ欠如で not_found（IFRS/US-GAAP/非連結等。`goodwill_and_intangibles` note_type とは別経路）。

