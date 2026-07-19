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

    /// normalize が nil を返す会社（銀行2社は指標概念が別、US-GAAP 2社は segments facts に
    /// 売上自体が無く、いずれも segmentExternalRevenueTags に一致するタグを持たない）。
    /// オークマ（6103）は別の理由で nil: `SegmentExtractor.extractSegmentInfo` の
    /// axis-aware swap（docs/segment-normalization-concept.md 今後の検討事項3）により、
    /// golden の "segments" が xbrl_facts（地域別）から html_table（収益認識１由来の製品別）
    /// に変わった。SegmentNormalizer.normalize は method=="xbrl_facts" のみ対象なので nil になる
    /// （html_table 側の正規化は RevenueRecognitionLLMNormalizer が別途担う）。
    private static let expectedNilCodes: Set<String> = ["4901", "6103", "7751", "8306", "8316"]

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

    /// オークマ実データ（学び10）を smoke golden から切り離してハードコードする。
    /// `SegmentExtractor.extractSegmentInfo`（`Sources/BlueTicker/Analysis/SegmentExtractor.swift`）
    /// が axis-aware swap（収益認識関係注記へのフォールバック）を持つようになったため、
    /// `smoke/segment_expected.json["S100W043"]["segments"]` の中身は将来 xbrl_facts から
    /// html_table（収益認識１由来）に変わりうる。このテストは `SegmentNormalizer.classifyAxis`
    /// 自体の分類ロジック（「地域名 member のみなら geography」）をロックインするためのものなので、
    /// ライブ抽出結果が更新されても独立して守られるよう、既知の地域名 member を直接構築する。
    @Test func okumaSegmentsAxisIsGeography() throws {
        let result = SegmentResult(
            method: "xbrl_facts",
            tables: [],
            facts: [
                SegmentFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_JapanReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "JapanReportableSegmentsMember"],
                    value: 61_753_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                SegmentFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_AmericasReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "AmericasReportableSegmentsMember"],
                    value: 63_016_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                SegmentFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_EuropeReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "EuropeReportableSegmentsMember"],
                    value: 33_386_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                SegmentFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_AsiaAndPacificReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "AsiaAndPacificReportableSegmentsMember"],
                    value: 48_665_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: 206_820_000_000))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
    }

    @Test func businessTypeCompaniesAxisIsBusiness() throws {
        // 6103（オークマ）は expectedNilCodes に含まれるため自動的に除外される。
        let businessCodes: [(code: String, docID: String, name: String)] = Self.fullYearCompanies.filter {
            !Self.expectedNilCodes.contains($0.code)
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

    // MARK: - ゴールデン値回帰（ユーザー確認済み、2026-07-18）
    //
    // smoke/segment_breakdown_expected.json は sales/profit の実額をユーザーが目視確認して
    // 記録したゴールデン値（share・利益率のような派生値は含めない）。オークマは segments の
    // 軸が地域別（既知）で事業別ブレークダウンではないため、このゴールデン集合から除外する。

    @Test func matchesUserConfirmedGoldenSalesAndProfit() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/segment_breakdown_expected.json")
        let data = try Data(contentsOf: path)
        let golden = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])

        for (docID, entry) in golden {
            let code = try #require(entry["code"] as? String)
            let name = try #require(entry["name"] as? String)
            let expectedRows = try #require(entry["rows"] as? [[String: Any]])

            let snap = try #require(try Self.snapshot(code: code, docID: docID), "\(name): snapshot が nil")
            let actualByLabel = Dictionary(uniqueKeysWithValues: snap.rows.map { ($0.labelRaw, $0) })

            for expectedRow in expectedRows {
                let label = try #require(expectedRow["label"] as? String)
                let expectedSales = try #require((expectedRow["sales"] as? NSNumber)?.doubleValue)
                let expectedProfit = (expectedRow["profit"] as? NSNumber)?.doubleValue

                let actual = try #require(actualByLabel[label], "\(name): row \(label) が見つからない")
                #expect(actual.amount == expectedSales, "\(name)/\(label): sales \(actual.amount) != \(expectedSales)")
                #expect(actual.profit == expectedProfit, "\(name)/\(label): profit \(String(describing: actual.profit)) != \(String(describing: expectedProfit))")
            }
        }
    }
}
