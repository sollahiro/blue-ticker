import Testing
import Foundation
@testable import BlueTickerCore

/// SegmentNormalizer を smoke/segment_expected.json（golden facts）+ smoke/smoke_expected/*.json
/// （連結売上）に対して実行し、Stage 6 コモンモデルの挙動を検証する。
/// ライブ XBRL キャッシュは不要（golden JSON のみで完結する）。
@Suite struct SegmentNormalizerTests {

    private static let fullYearCompanies: [(code: String, docID: String, name: String)] = [
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

    /// segmentExternalRevenueTags に一致するタグを持たず normalize が nil を返す会社
    /// （銀行2社は指標概念が別、US-GAAP 2社は segments facts に売上自体が無い）。
    private static let expectedNilCodes: Set<String> = ["4901", "7751", "8306", "8316"]

    private static func loadGolden() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/segment_expected.json")
        let data = try Data(contentsOf: path)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    /// code に複数の fixture ファイルがある場合（例: 2871 は売上 null の年度を含む）に備え、
    /// ファイル名でソートした上で売上が取れる最初のファイルを決定的に採用する。
    private static func loadSales(code: String) throws -> Double? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent("smoke/smoke_expected")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let matches = files.filter { $0.hasPrefix("\(code)_") }.sorted()
        for file in matches {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let income = json?["income_statement"] as? [String: Any]
            if let sales = (income?["sales"] as? NSNumber)?.doubleValue {
                return sales
            }
        }
        return nil
    }

    private static func snapshot(code: String, docID: String) throws -> BreakdownSnapshot? {
        let golden = try loadGolden()
        guard let entry = golden[docID], let segDict = entry["segments"] as? [String: Any] else {
            Issue.record("\(code): smoke/segment_expected.json に segments フィクスチャがない")
            return nil
        }
        let result = SegmentResult(dictionary: segDict)
        guard let sales = try loadSales(code: code) else {
            Issue.record("\(code): smoke/smoke_expected に売上フィクスチャがない")
            return nil
        }
        return SegmentNormalizer.normalize(result, consolidatedSales: sales)
    }

    @Test func nonFinancialCompaniesConvergeToFullSegmentShare() throws {
        for (code, docID, name) in Self.fullYearCompanies where !Self.expectedNilCodes.contains(code) {
            let snap = try #require(try Self.snapshot(code: code, docID: docID), "\(name): snapshot が nil")
            let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
            #expect(segmentShare > 0.95 && segmentShare < 1.05, "\(name): segment share sum = \(segmentShare)")
        }
    }

    @Test func okumaSegmentsAxisIsGeography() throws {
        let snap = try #require(try Self.snapshot(code: "6103", docID: "S100W043"))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
    }

    @Test func businessTypeCompaniesAxisIsBusiness() throws {
        let businessCodes: [(code: String, docID: String, name: String)] = Self.fullYearCompanies.filter {
            $0.code != "6103" && !Self.expectedNilCodes.contains($0.code)
        }
        for (code, docID, name) in businessCodes {
            let snap = try #require(try Self.snapshot(code: code, docID: docID), "\(name): snapshot が nil")
            #expect(snap.axis == "business", "\(name): expected business axis, got \(snap.axis)")
        }
    }

    @Test func excludedCompaniesReturnNil() throws {
        for (code, docID, name) in Self.fullYearCompanies where Self.expectedNilCodes.contains(code) {
            let snap = try Self.snapshot(code: code, docID: docID)
            #expect(snap == nil, "\(name): expected nil (対象外) だが snapshot が返された")
        }
    }

    @Test func subtotalRowsExcludedFromDenominatorButKeptInRows() throws {
        // クボタ: ReconcilingItemsMember が rows に残るが share 合計には使われない。
        let snap = try #require(try Self.snapshot(code: "6326", docID: "S100XR0M"))
        #expect(snap.rows.contains(where: { $0.rowKind == "reconciling" }))
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.02)
    }
}
