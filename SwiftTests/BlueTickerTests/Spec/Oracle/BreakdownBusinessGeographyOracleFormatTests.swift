// business / geography breakdown 軸の外出し SPEC_ORACLE（.agents/skills/xbrl-development/SKILL.md）。
//
// smoke 固定11社を床にする。経路は2種:
// - `path=xbrl_facts`: BreakdownNormalizer の決定論出力（segment 行の実額）を突合
// - `path=llm_input`: LLM に渡す前の ExtractedBreakdown（method + tables）を突合
// - `path=not_found`: 抽出 method=not_found を突合
//
// LLM 正規化後の金額（`smoke/breakdown_{business,geography}_expected.json` のスポット監査用）は
// ネットワーク依存のため本床には含めない。渡す前データを固定することで、入力帰属の回帰を守る。

import Foundation
import Testing
@testable import BlueTickerCore

enum BreakdownSmokeOracleSupport {
    static let smokeDocs: [(code: String, docID: String, name: String)] = [
        ("2802", "S100VXJA", "味の素"),
        ("2871", "S100VYA0", "ニチレイ"),
        ("3490", "S100VU4O", "AZplanning"),
        ("4901", "S100W3XJ", "富士フイルム"),
        ("6103", "S100W043", "オークマ"),
        ("6326", "S100XR0M", "クボタ"),
        ("7269", "S100W4MT", "スズキ"),
        ("7422", "S100XRD8", "東邦レマック"),
        ("7751", "S100XTLJ", "キヤノン"),
        ("8306", "S100W4FB", "三菱UFJ"),
        ("8316", "S100W0S7", "三井住友"),
    ]

    static func smokeXbrlDir(_ docID: String) -> URL {
        SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
    }

    static func smokeCacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: smokeXbrlDir(docID).path)
    }

    static func withSmokeCache(_ docID: String, _ body: (URL) throws -> Void) async throws {
        await SmokeCacheSupport.ensureCached([docID])
        guard smokeCacheAvailable(docID) else { return }
        try body(smokeXbrlDir(docID))
    }

    static func loadExpectedEntry(fileURL: URL, docID: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        let raw = try JSONSerialization.jsonObject(with: data)
        let all = try #require(raw as? [String: [String: Any]])
        return try #require(all[docID])
    }

    static func loadSales(code: String) throws -> Double? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("smoke/smoke_expected")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for file in files.filter({ $0.hasPrefix("\(code)_") }).sorted() {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let income = json?["income_statement"] as? [String: Any]
            if let sales = (income?["sales"] as? NSNumber)?.doubleValue { return sales }
        }
        return nil
    }

    static func canonicalJSON(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    static func assertTablesMatch(expected: [[String: Any]], actual: [BreakdownTable], label: String) throws {
        #expect(expected.count == actual.count, Comment(rawValue: "\(label): tables count"))
        guard expected.count == actual.count else { return }
        for (i, (exp, act)) in zip(expected, actual).enumerated() {
            #expect(exp["heading"] as? String == act.heading, Comment(rawValue: "\(label) tables[\(i)].heading"))
            let expPeriod = exp["period"] is NSNull ? nil : exp["period"] as? String
            #expect(expPeriod == act.period, Comment(rawValue: "\(label) tables[\(i)].period"))
            #expect(exp["markdown"] as? String == act.markdown, Comment(rawValue: "\(label) tables[\(i)].markdown"))
        }
    }

    static func assertXbrlFactsRowsMatch(expectedEntry: [String: Any], snapshot: BreakdownSnapshot, label: String) throws {
        #expect(snapshot.axis == (expectedEntry["axis"] as? String))
        #expect(snapshot.denominatorTag == (expectedEntry["denominator_tag"] as? String))
        #expect(snapshot.needsReview == (expectedEntry["needs_review"] as? Bool))
        let expectedWarnings = expectedEntry["warnings"] as? [String] ?? []
        #expect(snapshot.warnings == expectedWarnings)

        if let expectedDen = (expectedEntry["denominator"] as? NSNumber)?.doubleValue {
            #expect(snapshot.denominator == expectedDen)
        }

        let expectedRows = try #require(expectedEntry["rows"] as? [[String: Any]])
        #expect(!expectedRows.isEmpty)
        let actualRows = snapshot.rows.filter { $0.rowKind == "segment" }.map { r -> [String: Any] in
            [
                "label_raw": r.labelRaw,
                "label": r.label ?? NSNull(),
                "amount": r.amount,
                "profit": r.profit ?? NSNull(),
                "row_kind": r.rowKind,
            ]
        }
        let actualJSON = try canonicalJSON(actualRows)
        let expectedJSON = try canonicalJSON(expectedRows)
        #expect(actualJSON == expectedJSON, Comment(rawValue: "\(label): rows mismatch"))
    }
}

@Suite struct BreakdownBusinessOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/breakdown_business_oracle_expected.json")

    private func assertMatchesOracle(docID: String, code: String, xbrlDir: URL) throws {
        let expected = try BreakdownSmokeOracleSupport.loadExpectedEntry(
            fileURL: Self.expectedFileURL, docID: docID)
        let path = try #require(expected["path"] as? String)
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)
        let sales = try BreakdownSmokeOracleSupport.loadSales(code: code)
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)

        switch path {
        case "not_found":
            #expect(segments.method == "not_found")
        case "llm_input":
            let method = try #require(expected["method"] as? String)
            #expect(segments.method == method)
            let tables = try #require(expected["tables"] as? [[String: Any]])
            try BreakdownSmokeOracleSupport.assertTablesMatch(
                expected: tables, actual: segments.tables, label: "\(docID).business")
        case "xbrl_facts":
            let snap = try #require(
                BreakdownNormalizer.normalize(
                    segments, consolidatedSales: sales, labelsByTag: labelsByTag),
                "\(docID): expected xbrl_facts snapshot")
            #expect(snap.axis == "business")
            try BreakdownSmokeOracleSupport.assertXbrlFactsRowsMatch(
                expectedEntry: expected, snapshot: snap, label: "\(docID).business")
        case "stacked_segment_pnl":
            // 積み上げセグメント損益表の決定論寄せ（売上→研究開発費→営業利益）。
            // LLM 入力床ではなく、sales/profit の公開キーまで固定する。
            let snap = try #require(
                StackedSegmentPnLNormalizer.normalize(
                    segments, consolidatedSales: sales),
                "\(docID): expected stacked_segment_pnl snapshot")
            #expect(snap.axis == "business")
            #expect(snap.sourceKind == "stacked_segment_pnl")
            try BreakdownSmokeOracleSupport.assertXbrlFactsRowsMatch(
                expectedEntry: expected, snapshot: snap, label: "\(docID).business")
        default:
            Issue.record("\(docID): unknown path \(path)")
        }
    }

    @Test func smokeBusinessAjinomotoMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", code: "2802", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessNichireiMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", code: "2871", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessAZplanningMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", code: "3490", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessFujifilmStackedSegmentPnLMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", code: "4901", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessOkumaLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", code: "6103", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessKubotaMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", code: "6326", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessSuzukiMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", code: "7269", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessTohoRemacMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", code: "7422", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessCanonLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", code: "7751", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessMUFGMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", code: "8306", xbrlDir: $0)
        }
    }

    @Test func smokeBusinessSMFGMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", code: "8316", xbrlDir: $0)
        }
    }
}

@Suite struct BreakdownGeographyOracleFormatTests {
    private static let expectedFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("smoke/breakdown_geography_oracle_expected.json")

    private func assertMatchesOracle(docID: String, code: String, xbrlDir: URL) throws {
        let expected = try BreakdownSmokeOracleSupport.loadExpectedEntry(
            fileURL: Self.expectedFileURL, docID: docID)
        let path = try #require(expected["path"] as? String)
        let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)
        let sales = try BreakdownSmokeOracleSupport.loadSales(code: code)
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)

        switch path {
        case "not_found":
            #expect(geography.method == "not_found")
        case "llm_input":
            let method = try #require(expected["method"] as? String)
            #expect(geography.method == method)
            let tables = try #require(expected["tables"] as? [[String: Any]])
            try BreakdownSmokeOracleSupport.assertTablesMatch(
                expected: tables, actual: geography.tables, label: "\(docID).geography")
        case "xbrl_facts":
            let snap = try #require(
                BreakdownNormalizer.normalize(
                    geography, consolidatedSales: sales, labelsByTag: labelsByTag),
                "\(docID): expected xbrl_facts geography snapshot")
            #expect(snap.axis == "geography")
            try BreakdownSmokeOracleSupport.assertXbrlFactsRowsMatch(
                expectedEntry: expected, snapshot: snap, label: "\(docID).geography")
        default:
            Issue.record("\(docID): unknown path \(path)")
        }
    }

    @Test func smokeGeographyAjinomotoLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100VXJA") {
            try assertMatchesOracle(docID: "S100VXJA", code: "2802", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyNichireiLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100VYA0") {
            try assertMatchesOracle(docID: "S100VYA0", code: "2871", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyAZplanningNotFound() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100VU4O") {
            try assertMatchesOracle(docID: "S100VU4O", code: "3490", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyFujifilmLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W3XJ") {
            try assertMatchesOracle(docID: "S100W3XJ", code: "4901", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyOkumaLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W043") {
            try assertMatchesOracle(docID: "S100W043", code: "6103", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyKubotaLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100XR0M") {
            try assertMatchesOracle(docID: "S100XR0M", code: "6326", xbrlDir: $0)
        }
    }

    @Test func smokeGeographySuzukiLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W4MT") {
            try assertMatchesOracle(docID: "S100W4MT", code: "7269", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyTohoRemacNotFound() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100XRD8") {
            try assertMatchesOracle(docID: "S100XRD8", code: "7422", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyCanonLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100XTLJ") {
            try assertMatchesOracle(docID: "S100XTLJ", code: "7751", xbrlDir: $0)
        }
    }

    @Test func smokeGeographyMUFGLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W4FB") {
            try assertMatchesOracle(docID: "S100W4FB", code: "8306", xbrlDir: $0)
        }
    }

    @Test func smokeGeographySMFGLLMInputMatchesOracle() async throws {
        try await BreakdownSmokeOracleSupport.withSmokeCache("S100W0S7") {
            try assertMatchesOracle(docID: "S100W0S7", code: "8316", xbrlDir: $0)
        }
    }
}
