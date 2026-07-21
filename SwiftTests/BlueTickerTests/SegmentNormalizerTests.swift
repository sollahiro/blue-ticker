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

    /// normalize が nil を返す会社（US-GAAP 2社は segments facts に売上自体が無く、
    /// segmentExternalRevenueTags にも segmentBankGrossProfitTags にも一致するタグを持たない）。
    /// オークマ（6103）は別の理由で nil: `SegmentExtractor.extractSegmentInfo` の
    /// axis-aware swap（docs/segment-normalization-concept.md 今後の検討事項3）により、
    /// golden の "segments" が xbrl_facts（地域別）から html_table（収益認識１由来の製品別）
    /// に変わった。SegmentNormalizer.normalize は method=="xbrl_facts" のみ対象なので nil になる
    /// （html_table 側の正規化は RevenueRecognitionLLMNormalizer が別途担う）。
    /// 銀行2社（8306・8316）はここには含まれない: `normalizeBankBasis`（粗利益/営業純益基準）で
    /// 解決できるようになったため（issue調査 2026-07-21、下記 bankCompaniesResolveViaGrossProfitBasis 参照）。
    private static let expectedNilCodes: Set<String> = ["4901", "6103", "7751"]

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

    /// `OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember`
    /// は rowKind としては `segment` に分類される（分母への合算対象）が、事業/地域いずれの軸にも
    /// 断定できないため `classifyAxis` の判定候補からは除外され続けるべき。除外しないと、この
    /// member を持つ地域別報告企業が誤って business + needs_review に分類されてしまう。
    @Test func geographyAxisUnaffectedByOtherBusinessMember() throws {
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
                SegmentFact(
                    tag: "RevenuesFromExternalCustomers",
                    contextRef: "CurrentYearDuration_OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    dimensions: ["OperatingSegmentsAxis": "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember"],
                    value: 5_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: 211_820_000_000))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
        let other = try #require(
            snap.rows.first { $0.labelRaw == "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember" })
        #expect(other.rowKind == "segment")
    }

    /// `SegmentFact` を (member, value) の組から組み立てて normalize する軽量ヘルパー。
    /// 分母は行の合計値をそのまま使う（axis 判定のテストであり share の厳密検証は目的外）。
    private static func snapshot(labelsAndValues: [(String, Double)]) -> BreakdownSnapshot? {
        let facts = labelsAndValues.map { label, value in
            SegmentFact(
                tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_\(label)",
                dimensions: ["OperatingSegmentsAxis": label],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        let consolidatedSales = labelsAndValues.reduce(0.0) { $0 + $1.1 }
        return SegmentNormalizer.normalize(result, consolidatedSales: consolidatedSales)
    }

    /// 学び11（`docs/segment-normalization-concept.md`）の回帰テスト。実データ検証（2026-07-20）:
    /// 1802大林組・1812鹿島建設・1808長谷工・2413エムスリーはいずれも Domestic/Overseas を
    /// 含む事業区分名（「国内建築」「海外事業」等）の混在で誤って needs_review=true になっていた。
    /// axis=business の正しさは sum(segment)≈denominator でユーザーが確認済み。
    @Test func domesticOverseasPrefixedBusinessSegmentsDoNotTriggerNeedsReview() throws {
        let cases: [(name: String, rows: [(String, Double)])] = [
            ("大林組(1802)", [
                ("DomesticBuildingConstructionMember", 30_000_000_000),
                ("OverseasBuildingConstructionMember", 20_000_000_000),
                ("DomesticCivilEngineeringMember", 25_000_000_000),
                ("OverseasCivilEngineeringMember", 15_000_000_000),
                ("RealEstateMember", 10_000_000_000),
            ]),
            ("鹿島建設(1812)", [
                ("CivilEngineeringBusinessMember", 30_000_000_000),
                ("BuildingConstructionBusinessMember", 30_000_000_000),
                ("DevelopmentBusinessEtcMember", 20_000_000_000),
                ("DomesticAssociatedCompaniesMember", 10_000_000_000),
                ("OverseasAssociatedCompaniesMember", 10_000_000_000),
            ]),
            ("長谷工コーポレーション(1808)", [
                ("ConstructionRelatedBusinessMember", 40_000_000_000),
                ("RealEstateRelatedBusinessMember", 30_000_000_000),
                ("ManagementAndOperationBusinessMember", 20_000_000_000),
                ("OverseasBusinessMember", 10_000_000_000),
            ]),
            ("エムスリー(2413)", [
                ("CareerSolutionMember", 40_000_000_000),
                ("EvidenceMember", 30_000_000_000),
                ("MedicalPlatformMember", 20_000_000_000),
                ("OverseasReportableSegmentMember", 10_000_000_000),
            ]),
        ]

        for testCase in cases {
            let snap = try #require(Self.snapshot(labelsAndValues: testCase.rows), "\(testCase.name): snapshot が nil")
            #expect(snap.axis == "business", "\(testCase.name): expected business axis, got \(snap.axis)")
            #expect(snap.needsReview == false, "\(testCase.name): expected needsReview=false")
        }
    }

    /// 対照群: 特定地域名（Japan 等）が事業区分名の一部として混在する場合は、
    /// これまで通り needs_review を立てる（学び11の緩和は Domestic/Overseas 限定）。
    @Test func specificGeographyNameMixedWithBusinessSegmentsStillTriggersNeedsReview() throws {
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("FoodsBusinessMember", 40_000_000_000),
            ("ChemicalsBusinessMember", 30_000_000_000),
            ("JapanBusinessMember", 30_000_000_000),
        ]))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == true)
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

    // MARK: - 銀行の粗利益/営業純益基準（issue調査 2026-07-21）

    @Test func bankCompaniesResolveViaGrossProfitBasis() throws {
        // 三菱UFJ（NetRevenue）・三井住友（ConsolidatedGrossProfit）はいずれも外部売上高の
        // 概念を持たないため通常経路では nil になっていたが、粗利益/営業純益基準で解決できる。
        let mufg = try #require(try Self.snapshot(code: "8306", docID: "S100W4FB"))
        #expect(mufg.denominatorTag == "NetRevenue")
        #expect(mufg.axis == "business")
        #expect(mufg.needsReview == false)
        #expect(mufg.rows.contains { $0.labelRaw == "RetailAndDigitalBusinessGroupMember" && $0.rowKind == "segment" })
        #expect(mufg.rows.contains { $0.labelRaw == "GlobalMarketsBusinessGroupMember" && $0.rowKind == "segment" })
        let mufgSegmentShare = mufg.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(mufgSegmentShare - 1.0) < 0.02)

        let smfg = try #require(try Self.snapshot(code: "8316", docID: "S100W0S7"))
        #expect(smfg.denominatorTag == "ConsolidatedGrossProfit")
        #expect(smfg.axis == "business")
        #expect(smfg.needsReview == false)
        #expect(smfg.rows.contains { $0.labelRaw == "WholesaleBusinessUnitReportableSegmentMember" && $0.rowKind == "segment" })
        #expect(smfg.rows.contains { $0.labelRaw == "RetailBusinessUnitReportableSegmentMember" && $0.rowKind == "segment" })
        #expect(smfg.rows.contains { $0.labelRaw == "HeadOfficeAccountsEtcReportableSegmentMember" && $0.rowKind == "reconciling" })
    }

    @Test func mizuhoResolvesViaGrossProfitBasisWithBankSpecificTagNames() throws {
        // みずほは三菱UFJ・三井住友とも異なる独自の長いタグ名を使う（実データ検証、issue調査
        // 2026-07-21）。golden fixture が無いため実データ（S100YF8Y, 2026-06-19提出）の値を
        // 直接使う合成テスト。「その他」（OtherReportableSegmentsMember）は小計ではなく
        // 実際に粗利益を持つ事業区分として segment 扱いになる（合計と一致することを確認済み）。
        let grossProfitTag =
            "GrossProfitsExcludingTheAmountsOfCreditCostsOfTrustAccountsIncludingNetGainsLossesRelatedToETFsAndOthersSegmentInformation"
        let netOperatingProfitTag =
            "NetBusinessProfitsExcludingTheAmountsOfCreditCostsOfTrustAccountsBeforeReversalOfProvisionForGeneralAllowanceForLoanLossesIncludingNetGainsLossesRelatedToETFsAndOthersSegmentInformation"
        func fact(_ tag: String, _ member: String, _ value: Double) -> SegmentFact {
            SegmentFact(
                tag: tag, contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact(grossProfitTag, "RBCReportableSegmentMember", 984_610_000_000),
            fact(grossProfitTag, "CIBCReportableSegmentMember", 739_268_000_000),
            fact(grossProfitTag, "GCIBCReportableSegmentMember", 856_952_000_000),
            fact(grossProfitTag, "GMCReportableSegmentMember", 664_856_000_000),
            fact(grossProfitTag, "AMCReportableSegmentMember", 73_572_000_000),
            fact(grossProfitTag, "OtherReportableSegmentsMember", 196_415_000_000),
            fact(grossProfitTag, "ReportableSegmentsMember", 3_515_673_000_000),
            fact(netOperatingProfitTag, "RBCReportableSegmentMember", 237_515_000_000),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominatorTag == grossProfitTag)
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
        #expect(snap.rows.contains { $0.labelRaw == "OtherReportableSegmentsMember" && $0.rowKind == "segment" })
        #expect(snap.rows.first { $0.labelRaw == "RBCReportableSegmentMember" }?.profit == 237_515_000_000)
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.001)
    }

    @Test func bankDenominatorPrefersTrueGrandTotalOverPartialTotalWhenSegmentIsNegative() throws {
        // 回帰テスト: 市場部門が赤字の期は「顧客部門のみの部分合計」が「全社合計」より大きくなり、
        // 単純な最大値採用だと部分合計を誤って分母に選んでしまう。segment 行の合計に最も近い値
        // （＝真の全社合計）を選ぶ必要がある。
        let facts = [
            SegmentFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_RetailMember",
                dimensions: ["OperatingSegmentsAxis": "RetailMember"],
                value: 900_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_GlobalMarketsBusinessGroupMember",
                dimensions: ["OperatingSegmentsAxis": "GlobalMarketsBusinessGroupMember"],
                value: -300_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_TotalMember",
                dimensions: ["OperatingSegmentsAxis": "TotalMember"],
                value: 600_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_TotalOfCustomerBusinessUnitMember",
                dimensions: ["OperatingSegmentsAxis": "TotalOfCustomerBusinessUnitMember"],
                value: 900_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominator == 600_000_000_000)
    }

    @Test func bankDenominatorFarFromSegmentSumSetsNeedsReview() throws {
        // Grok 4.5 レビュー指摘の回帰テスト: 小計候補が1件しかない場合、距離チェックが
        // スキップされて needsReview が立たない穴があった。名称一致する小計しか無く、
        // それが segment 行合計から大きく乖離している（ここでは全社合計タグが部分合計しか
        // 無いケースを模す）ときは、採用した値であっても要確認とする。
        let facts = [
            SegmentFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_RetailMember",
                dimensions: ["OperatingSegmentsAxis": "RetailMember"],
                value: 500_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_WholesaleMember",
                dimensions: ["OperatingSegmentsAxis": "WholesaleMember"],
                value: 500_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                // 全社合計タグが名称未収載で、部分合計（顧客部門の一部のみ）しか無い状態を模す。
                tag: "NetRevenue", contextRef: "CurrentYearDuration_TotalOfCustomerBusinessUnitMember",
                dimensions: ["OperatingSegmentsAxis": "TotalOfCustomerBusinessUnitMember"],
                value: 600_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominator == 600_000_000_000)
        #expect(snap.needsReview == true)
        #expect(snap.warnings.contains("bank_denominator_far_from_segment_sum"))
    }

    // MARK: - ホワイトリスト外タグのカバレッジ/金額整合性フォールバック（issue調査 2026-07-21）
    //
    // NTT の TransactionsWithExternalCustomersIFRS・ファーストリテイリングの RevenueIFRS は
    // 実データ検証済みのためホワイトリストに追加済み（`segmentExternalRevenueTags`）。
    // 以下は「将来の未知タグ」向けフォールバック（`discoverDenominatorTagByCoverage`）自体を
    // ホワイトリストから独立して検証するため、架空のタグ名を使う。

    @Test func unknownTagResolvedByRatioFallbackWhenUnambiguous() throws {
        let facts = [
            SegmentFact(
                tag: "UnknownVendorSalesTag", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 60_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "UnknownVendorSalesTag", contextRef: "CurrentYearDuration_BetaMember",
                dimensions: ["OperatingSegmentsAxis": "BetaMember"],
                value: 40_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: 100_000_000_000))
        #expect(snap.denominatorTag == "UnknownVendorSalesTag")
        #expect(snap.needsReview == false)
        #expect(snap.rows.filter { $0.rowKind == "segment" }.count == 2)
    }

    @Test func nonRevenueBlacklistedTagIsNotAdoptedEvenWhenRatioMatches() throws {
        // AssetsIFRS はブラックリスト対象。たまたま合計が連結売上と近い値でも採用しない。
        let facts = [
            SegmentFact(
                tag: "AssetsIFRS", contextRef: "CurrentYearInstant_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        #expect(SegmentNormalizer.normalize(result, consolidatedSales: 100_000_000_000) == nil)
    }

    @Test func noTagMeetsRatioToleranceReturnsNil() throws {
        // 三菱商事型: セグメント別にタグ付けされているが売上系タグが1件も無い（実データ検証済み）。
        let facts = [
            SegmentFact(
                tag: "GrossProfitIFRS", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 5_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "NumberOfEmployees", contextRef: "CurrentYearInstant_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 1200, label: nil, unitRef: "pure", decimals: "0"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        #expect(SegmentNormalizer.normalize(result, consolidatedSales: 100_000_000_000) == nil)
    }

    @Test func netRevenueLikeTagIsNotAdoptedEvenWhenRatioMatches() throws {
        // Grok 4.5 レビュー指摘の回帰テスト: 銀行等金融機関の NetRevenueIFRS は、比率がたまたま
        // 一致してもブラックリストで除外され、外部売上として誤採用されない。
        let facts = [
            SegmentFact(
                tag: "NetRevenueIFRS", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        #expect(SegmentNormalizer.normalize(result, consolidatedSales: 100_000_000_000) == nil)
    }

    @Test func unnamedSubtotalRowExcludedByNumericSafetyNetDuringDiscovery() throws {
        // Grok 4.5 レビュー指摘の回帰テスト: 企業独自の合計行名（標準語彙に無い）が discovery の
        // 合計計算に混ざると比率が約2倍になり、正しい売上タグが誤って弾かれていた。
        // 本処理と同じ数値安全網（分母一致 member を小計とみなす）を discovery 側にも適用済み。
        let facts = [
            SegmentFact(
                tag: "VendorSalesTag", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 60_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "VendorSalesTag", contextRef: "CurrentYearDuration_BetaMember",
                dimensions: ["OperatingSegmentsAxis": "BetaMember"],
                value: 40_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                // 企業独自の合計行名（segmentSubtotalMemberNames に無い）。
                tag: "VendorSalesTag", contextRef: "CurrentYearDuration_CompanyWideTotalMember",
                dimensions: ["OperatingSegmentsAxis": "CompanyWideTotalMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: 100_000_000_000))
        #expect(snap.denominatorTag == "VendorSalesTag")
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.02)
    }

    @Test func multipleAmbiguousCandidatesSetNeedsReview() throws {
        // 2つの未知タグが両方とも合計±5%以内に収まる（外部売上っぽい語を含まない名前で作為的に作る）。
        let facts = [
            SegmentFact(
                tag: "VendorTagOne", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            SegmentFact(
                tag: "VendorTagTwo", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 101_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = SegmentResult(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(SegmentNormalizer.normalize(result, consolidatedSales: 100_000_000_000))
        #expect(snap.needsReview == true)
        #expect(snap.warnings.contains("denominator_tag_ambiguous"))
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
