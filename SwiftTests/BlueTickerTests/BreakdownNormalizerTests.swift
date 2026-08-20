import Testing
import Foundation
@testable import BlueTickerCore

/// BreakdownNormalizer を smoke/breakdown_extraction_expected.json（golden facts）+ smoke/smoke_expected/*.json
/// （連結売上）に対して実行し、内訳取り込み コモンモデルの挙動を検証する。
/// ライブ XBRL キャッシュは不要（golden JSON のみで完結する）。
@Suite struct BreakdownNormalizerTests {

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
    /// オークマ（6103）は別の理由で nil: `BreakdownExtractor.extractSegmentInfo` の
    /// axis-aware swap（docs/breakdown.md）により、
    /// golden の "segments" が xbrl_facts（地域別）から html_table（収益認識１由来の製品別）
    /// に変わった。BreakdownNormalizer.normalize は method=="xbrl_facts" のみ対象なので nil になる
    /// （html_table 側の正規化は RevenueRecognitionLLMNormalizer が別途担う）。
    /// 銀行2社（8306・8316）はここには含まれない: `normalizeBankBasis`（粗利益/営業純益基準）で
    /// 解決できるようになったため（issue調査 2026-07-21、下記 bankCompaniesResolveViaGrossProfitBasis 参照）。
    private static let expectedNilCodes: Set<String> = ["4901", "6103", "7751"]

    private static func loadGolden() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/breakdown_extraction_expected.json")
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
            Issue.record("\(code): smoke/breakdown_extraction_expected.json に segments フィクスチャがない")
            return nil
        }
        let result = ExtractedBreakdown(dictionary: segDict)
        guard let sales = try loadSales(code: code) else {
            Issue.record("\(code): smoke/smoke_expected に売上フィクスチャがない")
            return nil
        }
        return BreakdownNormalizer.normalize(result, consolidatedSales: sales)
    }

    @Test func nonFinancialCompaniesConvergeToFullSegmentShare() throws {
        for (code, docID, name) in Self.fullYearCompanies where !Self.expectedNilCodes.contains(code) {
            let snap = try #require(try Self.snapshot(code: code, docID: docID), "\(name): snapshot が nil")
            let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
            #expect(segmentShare > 0.95 && segmentShare < 1.05, "\(name): segment share sum = \(segmentShare)")
        }
    }

    /// オークマ実データ（学び10）を smoke golden から切り離してハードコードする。
    /// `BreakdownExtractor.extractSegmentInfo`（`Sources/BlueTicker/Analysis/BreakdownExtractor.swift`）
    /// が axis-aware swap（収益認識関係注記へのフォールバック）を持つようになったため、
    /// `smoke/breakdown_extraction_expected.json["S100W043"]["segments"]` の中身は将来 xbrl_facts から
    /// html_table（収益認識１由来）に変わりうる。このテストは `BreakdownNormalizer.classifyAxis`
    /// 自体の分類ロジック（「地域名 member のみなら geography」）をロックインするためのものなので、
    /// ライブ抽出結果が更新されても独立して守られるよう、既知の地域名 member を直接構築する。
    @Test func okumaSegmentsAxisIsGeography() throws {
        let result = ExtractedBreakdown(
            method: "xbrl_facts",
            tables: [],
            facts: [
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_JapanReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "JapanReportableSegmentsMember"],
                    value: 61_753_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_AmericasReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "AmericasReportableSegmentsMember"],
                    value: 63_016_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_EuropeReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "EuropeReportableSegmentsMember"],
                    value: 33_386_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_AsiaAndPacificReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "AsiaAndPacificReportableSegmentsMember"],
                    value: 48_665_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 206_820_000_000))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
    }

    /// `OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember`
    /// は rowKind としては `segment` に分類される（分母への合算対象）が、事業/地域いずれの軸にも
    /// 断定できないため `classifyAxis` の判定候補からは除外され続けるべき。除外しないと、この
    /// member を持つ地域別報告企業が誤って business + needs_review に分類されてしまう。
    @Test func geographyAxisUnaffectedByOtherBusinessMember() throws {
        let result = ExtractedBreakdown(
            method: "xbrl_facts",
            tables: [],
            facts: [
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_JapanReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "JapanReportableSegmentsMember"],
                    value: 61_753_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_AmericasReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "AmericasReportableSegmentsMember"],
                    value: 63_016_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_EuropeReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "EuropeReportableSegmentsMember"],
                    value: 33_386_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_AsiaAndPacificReportableSegmentsMember",
                    dimensions: ["OperatingSegmentsAxis": "AsiaAndPacificReportableSegmentsMember"],
                    value: 48_665_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
                BreakdownFact(
                    tag: "RevenuesFromExternalCustomers",
                    contextRef: "CurrentYearDuration_OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    dimensions: ["OperatingSegmentsAxis": "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember"],
                    value: 5_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
                ),
            ]
        )
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 211_820_000_000))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
        let other = try #require(
            snap.rows.first { $0.labelRaw == "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember" })
        #expect(other.rowKind == "segment")
    }

    /// `BreakdownFact` を (member, value) の組から組み立てて normalize する軽量ヘルパー。
    /// 分母は行の合計値をそのまま使う（axis 判定のテストであり share の厳密検証は目的外）。
    private static func snapshot(labelsAndValues: [(String, Double)]) -> BreakdownSnapshot? {
        let facts = labelsAndValues.map { label, value in
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_\(label)",
                dimensions: ["OperatingSegmentsAxis": label],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let consolidatedSales = labelsAndValues.reduce(0.0) { $0 + $1.1 }
        return BreakdownNormalizer.normalize(result, consolidatedSales: consolidatedSales)
    }

    /// 学び11（`docs/breakdown.md`）の回帰テスト。実データ検証（2026-07-20）:
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

    @Test func allDomesticOverseasPrefixedBusinessSegmentsResolveAsBusinessNotGeography() throws {
        // キッコーマン型の回帰（issue調査 2026-07-21）: 大林組等と異なり、全 member が
        // Domestic/Overseas を含む（RealEstateMember のような非地域名の混入が無い）場合、
        // 従来は「全メンバーが地域キーワードに一致 → geography」の完全一致判定が無条件に
        // 発動し、事業区分×国内海外クロス集計を誤って地域軸と判定していた。
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("DomesticFoodsManufacturingAndSalesReportableSegmentMember", 155_718_000_000),
            ("DomesticOthersReportableSegmentMember", 7_528_000_000),
            ("OverseasFoodsManufacturingAndSalesReportableSegmentMember", 149_491_000_000),
            ("OverseasFoodsWholesaleReportableSegmentMember", 432_800_000_000),
        ]))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
    }

    @Test func asahiStyleOceaniaMembersClassifyAsGeography() throws {
        // アサヒ型: Oceania がキーワードに無いと Japan/Europe/SoutheastAsia だけでは
        // 全一致にならず、収益認識の製品別マトリクスへ swap できない。
        #expect(
            BreakdownNormalizer.allMembersAreGeography([
                "JapanReportableSegmentMember",
                "EuropeReportableSegmentMember",
                "OceaniaReportableSegmentMember",
                "SoutheastAsiaReportableSegmentMember",
            ]))
    }

    @Test func mercariStyleJapanRegionAndUSMembersClassifyAsGeography() throws {
        // メルカリ型: JapanRegion / US。US・Region キーワードが無いと地域軸判定に乗らず、
        // 報告セグメント（地域）が business として採用されてしまう（実データ検証 2026-07-25）。
        #expect(
            BreakdownNormalizer.allMembersAreGeography([
                "JapanRegionReportableSegmentMember",
                "USReportableSegmentMember",
            ]))
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("JapanRegionReportableSegmentMember", 149_807_000_000),
            ("USReportableSegmentMember", 36_418_000_000),
        ]))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
    }

    @Test func eisaiStyleEMEAMembersClassifyAsGeography() throws {
        // エーザイ型: `EMEAReportableSegmentMember` は全大文字。`Emea` だけでは
        // case-sensitive contains にヒットせず、地域軸が business+axis_ambiguous になり
        // 製品別表（ニューロロジー/オンコロジー）へ進めない（実データ検証: S100YB05、2026-07-25）。
        #expect(
            BreakdownNormalizer.allMembersAreGeography([
                "AmericasReportableSegmentMember",
                "ChinaReportableSegmentMember",
                "EMEAReportableSegmentMember",
                "EastAsiaGlobalSouthReportableSegmentMember",
                "JapanReportableSegmentMember",
            ]))
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("AmericasReportableSegmentMember", 300_440_000_000),
            ("ChinaReportableSegmentMember", 130_745_000_000),
            ("EMEAReportableSegmentMember", 81_532_000_000),
            ("EastAsiaGlobalSouthReportableSegmentMember", 68_823_000_000),
            ("JapanReportableSegmentMember", 229_238_000_000),
            (
                "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                14_599_000_000
            ),
        ]))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
    }

    @Test func dentsuStyleAPACMembersClassifyAsGeography() throws {
        // 電通型（issue #163）: `APACReportableSegmentMember`。`Asia`/`Pacific` だけでは
        // ヒットせず、4地域が地域軸判定から外れる。
        #expect(
            BreakdownNormalizer.allMembersAreGeography([
                "JapanReportableSegmentMember",
                "AmericasReportableSegmentMember",
                "EMEAReportableSegmentMember",
                "APACReportableSegmentMember",
            ]))
        let facts = [
            ("JapanReportableSegmentMember", 608_310_000_000.0),
            ("AmericasReportableSegmentMember", 369_666_000_000.0),
            ("EMEAReportableSegmentMember", 338_401_000_000.0),
            ("APACReportableSegmentMember", 112_199_000_000.0),
            ("ReconcilingItemsMember", 6_668_000_000.0),
        ].map { label, value in
            BreakdownFact(
                tag: "Revenue2IFRS", contextRef: "CurrentYearDuration_\(label)",
                dimensions: ["OperatingSegmentsAxis": label],
                value: value, label: nil, unitRef: "JPY", decimals: "-6")
        }
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(
            BreakdownNormalizer.normalize(result, consolidatedSales: 1_435_245_000_000))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
        #expect(snap.denominatorTag == "Revenue2IFRS")
        let labels = Set(snap.rows.filter { $0.rowKind == "segment" }.map(\.labelRaw))
        #expect(labels == [
            "JapanReportableSegmentMember",
            "AmericasReportableSegmentMember",
            "EMEAReportableSegmentMember",
            "APACReportableSegmentMember",
        ])
    }

    /// INPEX旧filings型（J-GAAP時代）の回帰: 報告セグメントが Americas/AsiaAndOceania/
    /// Eurasia/Japan/MiddleEastAndAfrica という純粋な地域区分。`Eurasia`/`MiddleEastAndAfrica`
    /// が `segmentGeographyMemberKeywords` に無いと NXHD 免除条件（裸地域2件以上+非地域事業2件
    /// 以上）に誤ってヒットし axis=business, needs_review=false に確定してしまう
    /// （実データ検証: S100QH2B、2026-07-25）。
    @Test func inpexLegacyFilingPureRegionalSegmentsClassifyAsGeography() throws {
        #expect(
            BreakdownNormalizer.allMembersAreGeography([
                "AmericasReportableSegmentMember",
                "AsiaAndOceaniaReportableSegmentMember",
                "EurasiaReportableSegmentMember",
                "JapanReportableSegmentMember",
                "MiddleEastAndAfricaReportableSegmentMember",
            ]))
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("AmericasReportableSegmentMember", 300_000_000_000),
            ("AsiaAndOceaniaReportableSegmentMember", 200_000_000_000),
            ("EurasiaReportableSegmentMember", 400_000_000_000),
            ("JapanReportableSegmentMember", 500_000_000_000),
            ("MiddleEastAndAfricaReportableSegmentMember", 100_000_000_000),
        ]))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
    }

    /// エーザイ旧filings型の回帰（Opus監査 finding #2、2026-07-25）: 地域5member
    /// （Americas/AsiaAndLatinAmerica/China/EMEA/Japan）+ 残余バケツ「OTCAndOthers」1件という
    /// 構成（実データ: S100LKNM/S100O9U7/S100R09Z、`segmentOtherBusinessMemberNames` 未収録の
    /// 残余名）。旧 NXHD 免除条件（裸地域2件以上 かつ 非地域事業1件以上）はこの構成にも誤って
    /// 一致し、地域別データが axis=business, needs_review=false のまま確定していた。
    /// 非地域事業の最低件数を2件に上げたことで、残余バケツ1件だけでは免除が外れ
    /// needs_review が正しく立つことを確認する。
    @Test func eisaiLegacyFilingWithSingleResidualBucketStillTriggersNeedsReview() throws {
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("AmericasReportableSegmentMember", 300_000_000_000),
            ("AsiaAndLatinAmericaReportableSegmentMember", 80_000_000_000),
            ("ChinaReportableSegmentMember", 130_000_000_000),
            ("EMEAReportableSegmentMember", 80_000_000_000),
            ("JapanReportableSegmentMember", 220_000_000_000),
            ("OTCAndOthersReportableSegmentMember", 40_000_000_000),
        ]))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == true)
    }

    @Test func bareDomesticOverseasMembersStillClassifyAsGeography() throws {
        // 対照群: 「DomesticMember」「OverseasMember」のように事業名を伴わない裸の地域区分は
        // 引き続き geography のまま（既知のトレードオフ、学び11参照）。
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("DomesticMember", 60_000_000_000),
            ("OverseasMember", 40_000_000_000),
        ]))
        #expect(snap.axis == "geography")
    }

    /// 対照群: 特定地域名が事業語を伴わず裸で**1件だけ**混在する場合は needs_review を立てる。
    @Test func bareSpecificGeographyMemberMixedWithBusinessSegmentsStillTriggersNeedsReview() throws {
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("FoodsBusinessMember", 40_000_000_000),
            ("ChemicalsBusinessMember", 30_000_000_000),
            ("JapanReportableSegmentMember", 30_000_000_000),
        ]))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == true)
    }

    /// 資生堂型: 複数の JapanBusiness / AmericasBusiness ラッパ＋TravelRetail でも
    /// NXHD 免除に乗せず needs_review を維持する（Opus 監査 2026-07-25）。
    @Test func shiseidoStyleBusinessWrappersStillTriggerNeedsReviewDespiteMultipleBareGeos() throws {
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("JapanBusinessReportableSegmentMember", 400_000_000_000),
            ("ChinaBusinessReportableSegmentMember", 200_000_000_000),
            ("AmericasBusinessReportableSegmentMember", 150_000_000_000),
            ("EMEABusinessReportableSegmentMember", 100_000_000_000),
            ("AsiaPacificBusinessReportableSegmentMember", 80_000_000_000),
            ("TravelRetailBusinessReportableSegmentMember", 70_000_000_000),
        ]))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == true)
        #expect(snap.warnings.contains("axis_ambiguous"))
    }

    @Test func nxhdLogisticsRegionsWithSpecialtyBusinessesDoNotTriggerNeedsReview() throws {
        // NXHD（9147）S100XTG8: ロジスティクスを地域展開（日本/米州/欧州/東アジア/
        // 南アジア・オセアニア）し、警備輸送・重量品建設・物流サポートと同居。
        // 地域行はロジスティクス内訳として残し、axis_ambiguous にしない
        // （ユーザー確認 2026-07-25）。
        func fact(_ member: String, _ value: Double, profit: Double? = nil) -> [BreakdownFact] {
            var facts = [
                BreakdownFact(
                    tag: "RevenueFromExternalCustomersIFRS",
                    contextRef: "CurrentYearDuration_\(member)",
                    dimensions: ["OperatingSegmentsAxis": member],
                    value: value, label: nil, unitRef: "JPY", decimals: "-6"
                )
            ]
            if let profit {
                facts.append(
                    BreakdownFact(
                        tag: "SegmentProfitLossIFRS",
                        contextRef: "CurrentYearDuration_\(member)",
                        dimensions: ["OperatingSegmentsAxis": member],
                        value: profit, label: nil, unitRef: "JPY", decimals: "-6"
                    ))
            }
            return facts
        }
        var facts: [BreakdownFact] = []
        facts += fact("JapanReportableSegmentMember", 1_222_355_000_000, profit: 44_511_000_000)
        facts += fact("TheAmericasReportableSegmentMember", 121_416_000_000, profit: 5_768_000_000)
        facts += fact("EuropeReportableSegmentMember", 513_815_000_000, profit: 4_796_000_000)
        facts += fact("EastAsiaReportableSegmentMember", 147_561_000_000, profit: 5_708_000_000)
        facts += fact("SouthAsiaAndOceaniaReportableSegmentMember", 129_006_000_000, profit: 3_257_000_000)
        facts += fact("SecurityTransportationReportableSegmentMember", 68_597_000_000, profit: 2_493_000_000)
        facts += fact(
            "HeavyHaulageAndConstructionReportableSegmentMember", 45_136_000_000, profit: 5_307_000_000)
        facts += fact("DistributionSupportReportableSegmentMember", 326_937_000_000, profit: 16_129_000_000)
        facts += fact("TotalOfReportableSegmentsAndOthersMember", 2_574_826_000_000)
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(
            BreakdownNormalizer.normalize(result, consolidatedSales: 2_574_826_000_000))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
        #expect(!snap.warnings.contains("axis_ambiguous"))
        #expect(snap.rows.contains {
            $0.labelRaw == "JapanReportableSegmentMember" && $0.rowKind == "segment"
                && $0.profit == 44_511_000_000
        })
        #expect(snap.rows.contains {
            $0.labelRaw == "SecurityTransportationReportableSegmentMember" && $0.rowKind == "segment"
        })
        #expect(snap.rows.contains {
            $0.labelRaw == "HeavyHaulageAndConstructionReportableSegmentMember"
                && $0.rowKind == "segment"
        })
        #expect(snap.rows.contains {
            $0.labelRaw == "DistributionSupportReportableSegmentMember" && $0.rowKind == "segment"
        })
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }
            .reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.001)
    }

    /// 学び11: 特定地域名＋汎用 Business ラッパだけのラベルは混在シグナルのまま
    /// （INPEX の OilAndGasJapan 免除を JapanBusiness まで広げない）。
    @Test func specificGeographyBusinessWrapperMixedWithBusinessSegmentsStillTriggersNeedsReview() throws {
        let snap = try #require(Self.snapshot(labelsAndValues: [
            ("FoodsBusinessMember", 40_000_000_000),
            ("ChemicalsBusinessMember", 30_000_000_000),
            ("JapanBusinessMember", 30_000_000_000),
        ]))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == true)
    }

    @Test func inpexProjectSegmentsWithEmbeddedJapanDoNotTriggerNeedsReview() throws {
        // INPEX（1605）実データ検証 2026-07-24: 報告セグメントは
        // 国内O&G / イクシスプロジェクト / その他プロジェクト（海外O&G）。
        // OilAndGasJapan に Japan が含まれるが事業・プロジェクト区分であり地域軸との混在ではない。
        // セグメント利益は ProfitLossAttributableToOwnersOfParentIFRS に載る。
        func fact(_ tag: String, _ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: tag, contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("RevenueFromExternalCustomersIFRS", "OilAndGasJapanReportableSegmentMember", 192_176_000_000),
            fact("RevenueFromExternalCustomersIFRS", "IchthysProjectReportableSegmentMember", 315_069_000_000),
            fact("RevenueFromExternalCustomersIFRS", "OtherProjectsReportableSegmentMember", 1_486_928_000_000),
            fact("RevenueFromExternalCustomersIFRS", "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember", 17_176_000_000),
            fact("RevenueFromExternalCustomersIFRS", "TotalOfReportableSegmentsAndOthersMember", 2_011_351_000_000),
            fact("ProfitLossAttributableToOwnersOfParentIFRS", "OilAndGasJapanReportableSegmentMember", 13_663_000_000),
            fact("ProfitLossAttributableToOwnersOfParentIFRS", "IchthysProjectReportableSegmentMember", 248_239_000_000),
            fact("ProfitLossAttributableToOwnersOfParentIFRS", "OtherProjectsReportableSegmentMember", 165_711_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 2_011_351_000_000))
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
        #expect(!snap.warnings.contains("axis_ambiguous"))
        #expect(
            snap.rows.first { $0.labelRaw == "OilAndGasJapanReportableSegmentMember" }?.profit
                == 13_663_000_000)
        #expect(
            snap.rows.first { $0.labelRaw == "IchthysProjectReportableSegmentMember" }?.profit
                == 248_239_000_000)
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
        func fact(_ tag: String, _ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
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
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominatorTag == grossProfitTag)
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
        #expect(snap.rows.contains { $0.labelRaw == "OtherReportableSegmentsMember" && $0.rowKind == "segment" })
        #expect(snap.rows.first { $0.labelRaw == "RBCReportableSegmentMember" }?.profit == 237_515_000_000)
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.001)
    }

    @Test func insuranceCompanyResolvesViaInsuranceRevenueBasis() throws {
        // 東京海上型の回帰（issue調査 2026-07-21）: 保険会社は外部売上高の概念を持たず
        // InsuranceRevenueIFRS（保険収益）/ InsuranceServiceResultIFRS（保険サービス損益）を使う。
        // 銀行基準と同じ内部小計基準の経路（normalizeInternalSubtotalBasis）で解決できる。
        func fact(_ tag: String, _ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: tag, contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("InsuranceRevenueIFRS", "JapanPCBusinessReportableSegmentMember", 3_040_655_000_000),
            fact("InsuranceRevenueIFRS", "JapanLifeBusinessReportableSegmentMember", 265_448_000_000),
            fact("InsuranceRevenueIFRS", "InternationalBusinessReportableSegmentMember", 4_448_332_000_000),
            fact("InsuranceRevenueIFRS", "SolutionAndOtherBusinessReportableSegmentMember", 0),
            fact("InsuranceRevenueIFRS", "ReconcilingItemsMember", -60_875_000_000),
            fact("InsuranceRevenueIFRS", "ReportableSegmentsMember", 7_754_436_000_000),
            fact("InsuranceServiceResultIFRS", "JapanPCBusinessReportableSegmentMember", 257_461_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominatorTag == "InsuranceRevenueIFRS")
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
        #expect(snap.rows.first { $0.labelRaw == "JapanPCBusinessReportableSegmentMember" }?.profit == 257_461_000_000)
        #expect(snap.rows.first { $0.labelRaw == "ReconcilingItemsMember" }?.rowKind == "reconciling")
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.001)
    }

    @Test func externalRevenueResolvesViaInternalSubtotalWhenConsolidatedSalesMissing() throws {
        // SOMPO / T&D / 東宝型（2026-07-24）: セグメント注記に外部顧客売上タグはあるが
        // 財務取り込み の years[].sales が null（保険の経常収益ラベルのみ等）のため分母を渡せない。
        // 売上ホワイトリストタグで内部小計基準へフォールバックできること。
        func fact(_ tag: String, _ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: tag, contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("RevenuesFromExternalCustomers", "FilmBusinessReportableSegmentsMember", 182_617_000_000),
            fact("RevenuesFromExternalCustomers", "IPAndAnimeBusinessReportableSegmentMember", 75_265_000_000),
            fact("RevenuesFromExternalCustomers", "TheatricalBusinessReportableSegmentsMember", 22_310_000_000),
            fact("RevenuesFromExternalCustomers", "RealEstateBusinessReportableSegmentsMember", 79_179_000_000),
            fact("RevenuesFromExternalCustomers", "ReportableSegmentsMember", 359_371_000_000),
            fact("OperatingIncome", "FilmBusinessReportableSegmentsMember", 37_302_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominatorTag == "RevenuesFromExternalCustomers")
        #expect(snap.axis == "business")
        #expect(snap.denominator == 359_371_000_000)
        #expect(
            snap.rows.first { $0.labelRaw == "FilmBusinessReportableSegmentsMember" }?.profit
                == 37_302_000_000)
    }

    @Test func entityLevelExternalRevenueIsKeptAsConsolidatedSubtotal() throws {
        // 第一生命型: 報告セグメント計と連結財務諸表計上額（dimension なし）が別値。
        // 後者を落とすと 9,873,251 が欠ける。分母は segment 合計に近い「計」のまま。
        func fact(_ member: String?, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers",
                contextRef: member.map { "CurrentYearDuration_\($0)" } ?? "CurrentYearDuration",
                dimensions: member.map { ["OperatingSegmentsAxis": $0] } ?? [:],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("DomesticInsuranceBusinessReportableSegmentMember", 7_708_824_000_000),
            fact("OverseasInsuranceBusinessReportableSegmentMember", 3_621_288_000_000),
            fact("OtherReportableSegmentsMember", 43_217_000_000),
            fact("ReportableSegmentsMember", 11_373_330_000_000),
            fact("ReconcilingItemsMember", 1_500_079_000_000),
            fact(nil, 9_873_251_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominator == 11_373_330_000_000)
        let entity = try #require(snap.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.amount == 9_873_251_000_000)
        #expect(entity.rowKind == "subtotal")
        #expect(snap.rows.contains {
            $0.labelRaw == "DomesticInsuranceBusinessReportableSegmentMember"
                && $0.amount == 7_708_824_000_000
        })
    }

    @Test func salesBasisTakesPriorityOverInternalSubtotalBasisWhenBothTagsPresent() throws {
        // 通常の売上高ホワイトリストタグが存在する会社（銀行・保険ではない大多数）は
        // 引き続き normalizeSalesBasis を優先する（normalizeInternalSubtotalBasis に
        // フォールバックしない）ことを確認する。
        let facts = [
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 60_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_BetaMember",
                dimensions: ["OperatingSegmentsAxis": "BetaMember"],
                value: 40_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 100_000_000_000))
        #expect(snap.denominatorTag == "RevenuesFromExternalCustomers")
        #expect(snap.denominator == 100_000_000_000)
    }

    @Test func salesBasisAlignsDenominatorWhenFinancialsSalesFarFromSegmentTotal() throws {
        // 高島屋型（S100Y4X5）: 財務取り込み は NetSales（売上高）だが、セグメント注記の
        // RevenuesFromExternalCustomers は営業収益ベース。小計に揃えて分母を差し替える。
        func fact(_ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers",
                contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("DepartmentStoresInJapanReportableSegmentsMember", 303_856_000_000),
            fact("OverseasDepartmentStoresReportableSegmentsMember", 34_310_000_000),
            fact("CommercialPropertyDevelopmentInJapanReportableSegmentsMember", 41_767_000_000),
            fact("OverseasCommercialPropertyDevelopmentReportableSegmentsMember", 15_738_000_000),
            fact("FinanceReportableSegmentsMember", 20_699_000_000),
            fact("ContractAndDesignReportableSegmentsMember", 33_240_000_000),
            fact(
                "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                42_756_000_000),
            fact("TotalOfReportableSegmentsAndOthersMember", 492_370_000_000),
            fact("ReportableSegmentsMember", 449_613_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(
            BreakdownNormalizer.normalize(result, consolidatedSales: 401_958_000_000))
        #expect(snap.denominator == 492_370_000_000)
        #expect(snap.warnings.contains("sales_denominator_aligned_to_segment_total"))
        #expect(snap.needsReview == false)
        #expect(snap.axis == "business")
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }
            .reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.001)
    }

    @Test func salesBasisAlignmentWithoutSubtotalSetsNeedsReview() throws {
        // 小計名が無く segmentSum だけに揃える場合は裏取りが弱いので要レビュー
        // （Opus 監査 2026-07-25）。
        func fact(_ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers",
                contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("AlphaReportableSegmentsMember", 60_000_000_000),
            fact("BetaReportableSegmentsMember", 40_000_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(
            BreakdownNormalizer.normalize(result, consolidatedSales: 80_000_000_000))
        #expect(snap.denominator == 100_000_000_000)
        #expect(snap.warnings.contains("sales_denominator_aligned_to_segment_total"))
        #expect(snap.needsReview == true)
    }

    @Test func bankDenominatorPrefersTrueGrandTotalOverPartialTotalWhenSegmentIsNegative() throws {
        // 回帰テスト: 市場部門が赤字の期は「顧客部門のみの部分合計」が「全社合計」より大きくなり、
        // 単純な最大値採用だと部分合計を誤って分母に選んでしまう。segment 行の合計に最も近い値
        // （＝真の全社合計）を選ぶ必要がある。
        let facts = [
            BreakdownFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_RetailMember",
                dimensions: ["OperatingSegmentsAxis": "RetailMember"],
                value: 900_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_GlobalMarketsBusinessGroupMember",
                dimensions: ["OperatingSegmentsAxis": "GlobalMarketsBusinessGroupMember"],
                value: -300_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_TotalMember",
                dimensions: ["OperatingSegmentsAxis": "TotalMember"],
                value: 600_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_TotalOfCustomerBusinessUnitMember",
                dimensions: ["OperatingSegmentsAxis": "TotalOfCustomerBusinessUnitMember"],
                value: 900_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.denominator == 600_000_000_000)
    }

    @Test func bankDenominatorFarFromSegmentSumSetsNeedsReview() throws {
        // Grok 4.5 レビュー指摘の回帰テスト: 小計候補が1件しかない場合、距離チェックが
        // スキップされて needsReview が立たない穴があった。名称一致する小計しか無く、
        // それが segment 行合計から大きく乖離している（ここでは全社合計タグが部分合計しか
        // 無いケースを模す）ときは、採用した値であっても要確認とする。
        let facts = [
            BreakdownFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_RetailMember",
                dimensions: ["OperatingSegmentsAxis": "RetailMember"],
                value: 500_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "NetRevenue", contextRef: "CurrentYearDuration_WholesaleMember",
                dimensions: ["OperatingSegmentsAxis": "WholesaleMember"],
                value: 500_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                // 全社合計タグが名称未収載で、部分合計（顧客部門の一部のみ）しか無い状態を模す。
                tag: "NetRevenue", contextRef: "CurrentYearDuration_TotalOfCustomerBusinessUnitMember",
                dimensions: ["OperatingSegmentsAxis": "TotalOfCustomerBusinessUnitMember"],
                value: 600_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: nil))
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
            BreakdownFact(
                tag: "UnknownVendorSalesTag", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 60_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "UnknownVendorSalesTag", contextRef: "CurrentYearDuration_BetaMember",
                dimensions: ["OperatingSegmentsAxis": "BetaMember"],
                value: 40_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 100_000_000_000))
        #expect(snap.denominatorTag == "UnknownVendorSalesTag")
        #expect(snap.needsReview == false)
        #expect(snap.rows.filter { $0.rowKind == "segment" }.count == 2)
    }

    @Test func nonRevenueBlacklistedTagIsNotAdoptedEvenWhenRatioMatches() throws {
        // AssetsIFRS はブラックリスト対象。たまたま合計が連結売上と近い値でも採用しない。
        let facts = [
            BreakdownFact(
                tag: "AssetsIFRS", contextRef: "CurrentYearInstant_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        #expect(BreakdownNormalizer.normalize(result, consolidatedSales: 100_000_000_000) == nil)
    }

    @Test func noTagMeetsRatioToleranceReturnsNil() throws {
        // 三菱商事型: セグメント別にタグ付けされているが売上系タグが1件も無い（実データ検証済み）。
        let facts = [
            BreakdownFact(
                tag: "GrossProfitIFRS", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 5_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "NumberOfEmployees", contextRef: "CurrentYearInstant_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 1200, label: nil, unitRef: "pure", decimals: "0"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        #expect(BreakdownNormalizer.normalize(result, consolidatedSales: 100_000_000_000) == nil)
    }

    @Test func netRevenueLikeTagIsNotAdoptedEvenWhenRatioMatches() throws {
        // Grok 4.5 レビュー指摘の回帰テスト: 銀行等金融機関の NetRevenueIFRS は、比率がたまたま
        // 一致してもブラックリストで除外され、外部売上として誤採用されない。
        let facts = [
            BreakdownFact(
                tag: "NetRevenueIFRS", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        #expect(BreakdownNormalizer.normalize(result, consolidatedSales: 100_000_000_000) == nil)
    }

    @Test func unnamedSubtotalRowExcludedByNumericSafetyNetDuringDiscovery() throws {
        // Grok 4.5 レビュー指摘の回帰テスト: 企業独自の合計行名（標準語彙に無い）が discovery の
        // 合計計算に混ざると比率が約2倍になり、正しい売上タグが誤って弾かれていた。
        // 本処理と同じ数値安全網（分母一致 member を小計とみなす）を discovery 側にも適用済み。
        let facts = [
            BreakdownFact(
                tag: "VendorSalesTag", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 60_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "VendorSalesTag", contextRef: "CurrentYearDuration_BetaMember",
                dimensions: ["OperatingSegmentsAxis": "BetaMember"],
                value: 40_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                // 企業独自の合計行名（segmentSubtotalMemberNames に無い）。
                tag: "VendorSalesTag", contextRef: "CurrentYearDuration_CompanyWideTotalMember",
                dimensions: ["OperatingSegmentsAxis": "CompanyWideTotalMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 100_000_000_000))
        #expect(snap.denominatorTag == "VendorSalesTag")
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.02)
    }

    @Test func multipleAmbiguousCandidatesSetNeedsReview() throws {
        // 2つの未知タグが両方とも合計±5%以内に収まる（外部売上っぽい語を含まない名前で作為的に作る）。
        let facts = [
            BreakdownFact(
                tag: "VendorTagOne", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 100_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
            BreakdownFact(
                tag: "VendorTagTwo", contextRef: "CurrentYearDuration_AlphaMember",
                dimensions: ["OperatingSegmentsAxis": "AlphaMember"],
                value: 101_000_000_000, label: nil, unitRef: "JPY", decimals: "-6"
            ),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 100_000_000_000))
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

    // MARK: - 個別企業の needs_review 是正（issue調査 2026-07-22、実データ検証済み）

    @Test func totoGlobalHousingEquipmentMemberIsSubtotalNotSegment() throws {
        // TOTO（5332）: GlobalHousingEquipmentBusinessReportableSegmentMember(669,742百万円)は
        // 日本住設(479,663)＋海外住設4地域（米州75,623/アジア・オセアニア54,914/欧州5,677/
        // 中国53,863＝計190,077）の合計に一致する独立していない集計行であり、真の報告セグメントは
        // セラミック事業＋日本住設＋海外住設4地域の6行。Global を segment のまま数えると
        // 売上が二重計上される。
        func fact(_ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("AdvancedCeramicsBusinessReportableSegmentMember", 67_414_000_000),
            fact("AmericasReportableSegmentMember", 75_623_000_000),
            fact("AsiaOceaniaReportableSegmentMember", 54_914_000_000),
            fact("EuropeReportableSegmentMember", 5_677_000_000),
            fact("GlobalHousingEquipmentBusinessReportableSegmentMember", 669_742_000_000),
            fact("JapanHousingEquipmentBusinessReportableSegmentMember", 479_663_000_000),
            fact("MainlandChinaBusinessReportableSegmentMember", 53_863_000_000),
            fact("ReconcilingItemsMember", 0),
            fact("ReportableSegmentsMember", 737_156_000_000),
            fact("TotalOfReportableSegmentsAndOthersMember", 737_441_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 737_441_000_000))

        let global = try #require(snap.rows.first { $0.labelRaw == "GlobalHousingEquipmentBusinessReportableSegmentMember" })
        #expect(global.rowKind == "subtotal")
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
        #expect(!snap.warnings.contains("axis_ambiguous"))
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.02)
        #expect(snap.rows.contains {
            $0.labelRaw == "JapanHousingEquipmentBusinessReportableSegmentMember" && $0.rowKind == "segment"
        })
        #expect(snap.rows.contains {
            $0.labelRaw == "AmericasReportableSegmentMember" && $0.rowKind == "segment"
        })
        #expect(snap.rows.contains {
            $0.labelRaw == "AsiaOceaniaReportableSegmentMember" && $0.rowKind == "segment"
        })
    }

    @Test func totoGlobalHousingEquipmentPluralMemberIsSubtotalNotSegment() throws {
        // TOTO（5332）過去期分の回帰（2026-07-23、実データ再検証）: 2210e6bは単数形
        // GlobalHousingEquipmentBusinessReportableSegmentMemberのみをホワイトリストに
        // 追加したが、過去5期（2021〜2025年度、doc S100W0X9等）はmember名が複数形
        // （...ReportableSegments Member）で、実際の格納済みDBを確認すると解消していなかった。
        // 数値はdoc S100W0X9（2025年度）の実データ: Global住設673,852百万円 ≈
        // 日本住設481,346＋米州70,478＋アジア・オセアニア50,220＋中国66,924＋欧州4,882
        // （=673,850、差2は開示側の丸め）。
        func fact(_ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("AdvancedCeramicsBusinessReportableSegmentsMember", 50_325_000_000),
            fact("AmericasBusinessReportableSegmentsMember", 70_478_000_000),
            fact("AsiaOceaniaBusinessReportableSegmentsMember", 50_220_000_000),
            fact("ChinaBusinessReportableSegmentsMember", 66_924_000_000),
            fact("EuropeBusinessReportableSegmentsMember", 4_882_000_000),
            fact("GlobalHousingEquipmentBusinessReportableSegmentsMember", 673_852_000_000),
            fact("JapanHousingEquipmentBusinessReportableSegmentsMember", 481_346_000_000),
            fact(
                "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                277_000_000),
            fact("ReconcilingItemsMember", 0),
            fact("ReportableSegmentsMember", 724_177_000_000),
            fact("TotalOfReportableSegmentsAndOthersMember", 724_454_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 724_454_000_000))

        let global = try #require(
            snap.rows.first { $0.labelRaw == "GlobalHousingEquipmentBusinessReportableSegmentsMember" })
        #expect(global.rowKind == "subtotal")
        #expect(snap.axis == "business")
        let segmentShare = snap.rows.filter { $0.rowKind == "segment" }.reduce(0.0) { $0 + ($1.share ?? 0) }
        #expect(abs(segmentShare - 1.0) < 0.02)
        // 米州/アジア等は地域名＋Business ラッパだけだが、日本住設（HousingEquipment）と同居する
        // TOTO 型の海外住設内訳 → 事業区分として採用（ユーザー確認 2026-07-25）。
        #expect(snap.needsReview == false)
        #expect(!snap.warnings.contains("axis_ambiguous"))
    }

    @Test func mauiRetailFinTechResolvesViaSingularRevenueTagWithoutAmbiguity() throws {
        // 丸井グループ（8252）: 分母タグが単数形の RevenueFromExternalCustomers（IFRS接尾辞なし）で、
        // ホワイトリスト未収載だった当時はカバレッジ発見フォールバックが複数候補を検出し
        // denominator_tag_ambiguous を立てていた。ホワイトリストに追加後は候補が一意に決まり
        // needsReview が解消する。行内容自体（小売・フィンテック）は既に正しかった。
        func fact(_ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenueFromExternalCustomers", contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("FinTechReportableSegmentMember", 195_824_000_000),
            fact("RetailReportableSegmentMember", 81_037_000_000),
            fact("ReconcilingItemsMember", 0),
            fact("TotalOfReportableSegmentsAndOthersMember", 276_862_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 276_862_000_000))

        #expect(snap.denominatorTag == "RevenueFromExternalCustomers")
        #expect(snap.axis == "business")
        #expect(snap.needsReview == false)
        #expect(snap.warnings.isEmpty)
        #expect(snap.rows.contains { $0.labelRaw == "FinTechReportableSegmentMember" && $0.rowKind == "segment" })
        #expect(snap.rows.contains { $0.labelRaw == "RetailReportableSegmentMember" && $0.rowKind == "segment" })
    }

    @Test func mazdaGeographySegmentsWithOtherBucketResolveAsGeographyNotBusiness() throws {
        // マツダ（7261）: 有報に「単一の製品・サービスの区分（自動車関連事業）の外部顧客への
        // 売上高が、連結損益計算書の売上高の90％を超えるため、事業種類別セグメント情報の記載を
        // 省略しております」と明記されており、報告セグメントは地域別（Japan/NorthAmerica/Europe/
        // Other）のみ。この「Other」（その他地域）は地理キーワードに一致しないため、
        // allMembersAreGeography の完全一致判定が崩れ business+needsReview に誤分類されていた。
        func fact(_ member: String, _ value: Double) -> BreakdownFact {
            BreakdownFact(
                tag: "RevenuesFromExternalCustomers", contextRef: "CurrentYearDuration_\(member)",
                dimensions: ["OperatingSegmentsAxis": member],
                value: value, label: nil, unitRef: "JPY", decimals: "-6"
            )
        }
        let facts = [
            fact("EuropeReportableSegmentsMember", 859_557_000_000),
            fact("JapanReportableSegmentsMember", 900_173_000_000),
            fact("NorthAmericaReportableSegmentsMember", 2_561_746_000_000),
            fact("OtherReportableSegmentsMember", 596_696_000_000),
            fact("ReconcilingItemsMember", 0),
            fact("ReportableSegmentsMember", 4_918_172_000_000),
        ]
        let result = ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 4_918_172_000_000))

        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
        let other = try #require(snap.rows.first { $0.labelRaw == "OtherReportableSegmentsMember" })
        #expect(other.rowKind == "segment")
    }

    // MARK: - ゴールデン値回帰（ユーザー確認済み、2026-07-18）
    //
    // smoke/breakdown_expected.json は sales/profit の実額をユーザーが目視確認して
    // 記録したゴールデン値（share・利益率のような派生値は含めない）。オークマは segments の
    // 軸が地域別（既知）で事業別ブレークダウンではないため、このゴールデン集合から除外する。

    @Test func matchesUserConfirmedGoldenSalesAndProfit() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let path = root.appendingPathComponent("smoke/breakdown_expected.json")
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

    private static let otherBusinessMember =
        "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember"

    private static func employeeFact(_ member: String, _ value: Double) -> BreakdownFact {
        BreakdownFact(
            tag: "NumberOfEmployees", contextRef: "CurrentYearInstant_\(member)",
            dimensions: ["OperatingSegmentsAxis": member],
            value: value, label: nil, unitRef: "pure", decimals: "0")
    }

    private static func rdFact(_ member: String, _ value: Double) -> BreakdownFact {
        BreakdownFact(
            tag: "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",
            contextRef: "CurrentYearDuration_\(member)",
            dimensions: ["OperatingSegmentsAxis": member],
            value: value, label: nil, unitRef: "JPY", decimals: "-6")
    }

    /// 報告セグメント fact が親 member にしか無く、残る内訳がその他事業だけのとき
    /// 親を segment に昇格する（エーザイ S100YB05）。
    @Test func employeesPromotesSoleReportableSegmentsMemberAlongsideOtherBusiness() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: [
                    Self.employeeFact("ReportableSegmentsMember", 9_832),
                    Self.employeeFact(Self.otherBusinessMember, 711),
                ],
                total: 10_543, axis: breakdownAxisEmployees,
                labelsByTag: [
                    "ReportableSegmentsMember": "医薬品事業",
                    Self.otherBusinessMember: "その他事業",
                ]))
        #expect(snap.needsReview == false)
        #expect(snap.warnings.isEmpty)
        let pharma = try #require(snap.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(pharma.rowKind == "segment")
        #expect(pharma.amount == 9_832)
        #expect(pharma.label == "医薬品事業")
        let other = try #require(snap.rows.first { $0.labelRaw == Self.otherBusinessMember })
        #expect(other.rowKind == "segment")
        #expect(other.amount == 711)
    }

    /// 子セグメントが fact として載っている親小計は昇格しない（サッポロ型）。
    @Test func employeesKeepsReportableSegmentsAsSubtotalWhenChildrenArePresent() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: [
                    Self.employeeFact("AlcoholicBeveragesReportableSegmentMember", 3_565),
                    Self.employeeFact("FoodAndSoftDrinksReportableSegmentMember", 2_255),
                    Self.employeeFact("RealEstateReportableSegmentMember", 138),
                    Self.employeeFact("ReportableSegmentsMember", 5_958),
                    Self.employeeFact("CorporateSharedMember", 144),
                ],
                total: 6_102, axis: breakdownAxisEmployees))
        #expect(snap.needsReview == false)
        let rs = try #require(snap.rows.first { $0.labelRaw == "ReportableSegmentsMember" })
        #expect(rs.rowKind == "subtotal")
    }

    /// 子と合計が分母に一致する親セグメントを subtotal へ落とす（花王 S100XT6G）。
    @Test func employeesDemotesParentSegmentThatDoubleCountsChildren() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: [
                    Self.employeeFact("BusinessConnectedBusinessReportableSegmentMember", 841),
                    Self.employeeFact("ChemicalBusinessReportableSegmentMember", 4_068),
                    Self.employeeFact("CosmeticsBusinessReportableSegmentMember", 9_331),
                    Self.employeeFact("GlobalConsumerCareBusinessReportableSegmentMember", 26_192),
                    Self.employeeFact("HealthBeautyCareBusinessReportableSegmentMember", 7_521),
                    Self.employeeFact("HygieneLivingCareBusinessReportableSegmentMember", 8_499),
                    Self.employeeFact("CorporateSharedMember", 1_254),
                ],
                total: 31_514, axis: breakdownAxisEmployees))
        #expect(snap.needsReview == false)
        #expect(snap.warnings.isEmpty)
        let parent = try #require(
            snap.rows.first { $0.labelRaw == "GlobalConsumerCareBusinessReportableSegmentMember" })
        #expect(parent.rowKind == "subtotal")
        let reconciled = snap.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(reconciled == 31_514)
    }

    /// 消去を足すと分母を超え、引くと一致するときは負の reconciling にする（NTT S100YCP3）。
    @Test func researchAndDevelopmentSubtractsEliminationWhenThatReconcilesToTotal() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: [
                    Self.rdFact("IntegratedICTBusinessReportableSegmentMember", 123_776_000_000),
                    Self.rdFact("GlobalSolutionsBusinessReportableSegmentMember", 41_993_000_000),
                    Self.rdFact("RegionalCommunicationsBusinessReportableSegmentMember", 82_110_000_000),
                    Self.rdFact("OthersRealEstateEnergyAndOthersReportableSegmentMember", 149_987_000_000),
                    Self.rdFact("ReportableSegmentsMember", 397_866_000_000),
                    Self.rdFact("UnallocatedAmountsAndEliminationMember", 119_217_000_000),
                ],
                total: 278_649_000_000, axis: breakdownAxisResearchAndDevelopment))
        #expect(snap.needsReview == false)
        let elim = try #require(
            snap.rows.first { $0.labelRaw == "UnallocatedAmountsAndEliminationMember" })
        #expect(elim.rowKind == "reconciling")
        #expect(elim.amount == -119_217_000_000)
        let reconciled = snap.rows.filter { $0.rowKind == "segment" || $0.rowKind == "reconciling" }
            .map(\.amount).reduce(0, +)
        #expect(reconciled == 278_649_000_000)
    }

    /// 未配賦を足すと分母に一致するときは正のまま残す（味の素 S100VXJA）。
    @Test func researchAndDevelopmentKeepsUnallocatedPositiveWhenAddingReconciles() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: [
                    Self.rdFact("SeasoningsAndFoodsReportableSegmentMember", 10_000_000_000),
                    Self.rdFact("FrozenFoodsReportableSegmentMember", 5_000_000_000),
                    Self.rdFact("HealthcareAndOthersReportableSegmentMember", 11_212_000_000),
                    Self.rdFact("UnallocatedAmountsAndEliminationMember", 9_562_000_000),
                ],
                total: 35_774_000_000, axis: breakdownAxisResearchAndDevelopment))
        #expect(snap.needsReview == false)
        let unallocated = try #require(
            snap.rows.first { $0.labelRaw == "UnallocatedAmountsAndEliminationMember" })
        #expect(unallocated.amount == 9_562_000_000)
        #expect(unallocated.rowKind == "reconciling")
    }

    /// 未タグ残差で分母から大きく欠ける場合は needs_review のまま（ホンダ四輪欠落）。
    @Test func researchAndDevelopmentKeepsNeedsReviewWhenTaggedSegmentsAreFarBelowTotal() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: [
                    Self.rdFact("MotorcycleBusinessReportableSegmentMember", 112_300_000_000),
                    Self.rdFact("PowerProductAndOtherBusinessesReportableSegmentMember", 33_200_000_000),
                ],
                total: 1_540_646_000_000, axis: breakdownAxisResearchAndDevelopment))
        #expect(snap.needsReview == true)
        #expect(snap.warnings.contains("research_and_development_segment_sum_far_from_total"))
        #expect(snap.rows.contains { $0.labelRaw == "MotorcycleBusinessReportableSegmentMember" })
    }

    /// statement-notes の RD note 廃止後、セグメント dimension が無くても全社合計だけで
    /// breakdown RD 軸が成立する（オークマ型）。呼び出し側が実タグ名（`totalTag`）を渡せば
    /// denominatorTag に反映される（実データ: S100W043 で
    /// `ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities` を確認済み）。
    @Test func researchAndDevelopmentTotalOnlyWithoutSegmentFactsUsesCallerProvidedTag() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: [], total: 4_409_000_000,
                totalTag: "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities",
                axis: breakdownAxisResearchAndDevelopment))
        #expect(snap.axis == breakdownAxisResearchAndDevelopment)
        #expect(snap.denominator == 4_409_000_000)
        #expect(snap.denominatorTag == "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities")
        #expect(snap.rows.isEmpty)
        #expect(snap.needsReview == false)
    }

    /// `totalTag` が解決できない場合（呼び出し側が渡せなかった等）は従来通り
    /// `"company_financials"` にフォールバックする。
    @Test func researchAndDevelopmentTotalOnlyWithoutSegmentFactsFallsBackWhenTagUnresolved() throws {
        let snap = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: [], total: 4_409_000_000, axis: breakdownAxisResearchAndDevelopment))
        #expect(snap.denominatorTag == "company_financials")
    }

    /// 報告セグメントごとの情報に含まれる7指標を、smokeの実抽出factsから軸別に
    /// 正規化する床。各指標の denominator_tag は固定プレースホルダーではなく、
    /// fixture の実タグ候補のいずれかになることも確認する。
    @Test func segmentMetricAxesNormalizeSmokeFacts() throws {
        let golden = try Self.loadGolden()
        func facts(_ docID: String) throws -> [BreakdownFact] {
            let entry = try #require(golden[docID])
            let segments = try #require(entry["segments"] as? [String: Any])
            return ExtractedBreakdown(dictionary: segments).facts
        }
        func expectTag(_ snapshot: BreakdownSnapshot?, _ tags: [String]) throws {
            let snapshot = try #require(snapshot)
            #expect(tags.contains(snapshot.denominatorTag))
            #expect(!snapshot.rows.isEmpty)
        }

        let ajinomoto = try facts("S100VXJA")
        try expectTag(
            BreakdownNormalizer.normalizeSegmentAssets(facts: ajinomoto),
            Xbrl.segmentAssetsTags)
        try expectTag(
            BreakdownNormalizer.normalizeDepreciationAndAmortization(facts: ajinomoto),
            Xbrl.segmentDepreciationAndAmortizationTags)
        try expectTag(
            BreakdownNormalizer.normalizeImpairmentLoss(facts: ajinomoto),
            Xbrl.segmentImpairmentLossTags)
        try expectTag(
            BreakdownNormalizer.normalizeEquityMethodInvestments(facts: ajinomoto),
            Xbrl.segmentEquityMethodInvestmentTags)
        try expectTag(
            BreakdownNormalizer.normalizeCapitalExpenditures(facts: ajinomoto),
            Xbrl.segmentCapitalExpenditureTags)

        let nichirei = try facts("S100VYA0")
        try expectTag(
            BreakdownNormalizer.normalizeGoodwillAmortization(facts: nichirei),
            Xbrl.segmentGoodwillAmortizationTags)

        let azPlanning = try facts("S100VU4O")
        try expectTag(
            BreakdownNormalizer.normalizeNoncurrentAssetAdditions(facts: azPlanning),
            Xbrl.segmentNoncurrentAssetAdditionTags)
    }

    @Test func segmentMetricKeepsEntityTotalFactAsConsolidatedRow() throws {
        let facts = [
            BreakdownFact(
                tag: "AssetsIFRS", contextRef: "CurrentYearInstant_SegmentAMember",
                dimensions: ["OperatingSegmentsAxis": "SegmentAMember"],
                value: 80, label: nil, unitRef: "JPY", decimals: "0"),
            BreakdownFact(
                tag: "AssetsIFRS", contextRef: "CurrentYearInstant",
                dimensions: [:], value: 100, label: nil, unitRef: "JPY", decimals: "0"),
        ]
        let snapshot = try #require(BreakdownNormalizer.normalizeSegmentAssets(facts: facts))
        let entityTotal = try #require(snapshot.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entityTotal.amount == 100)
        #expect(entityTotal.rowKind == "subtotal")
    }

    @Test func mufgFixedAssetRowsUseBankSpecificTagsAndTotals() throws {
        let golden = try Self.loadGolden()
        let entry = try #require(golden["S100W4FB"])
        let segments = try #require(entry["segments"] as? [String: Any])
        let facts = ExtractedBreakdown(dictionary: segments).facts

        let assets = try #require(BreakdownNormalizer.normalizeSegmentAssets(facts: facts))
        #expect(assets.denominatorTag == "NoncurrentAssets")
        let assetsTotal = try #require(assets.rows.first { $0.labelRaw == "TotalMember" })
        #expect(assetsTotal.amount == 1_383_167_000_000)

        let additions = try #require(
            BreakdownNormalizer.normalizeNoncurrentAssetAdditions(facts: facts))
        #expect(additions.denominatorTag == "AdditionsOfFixedAssets")
        let additionsTotal = try #require(
            additions.rows.first { $0.labelRaw == "TotalMember" })
        #expect(additionsTotal.amount == 232_361_000_000)
    }

    @Test func nichireiUsesJgaapEquityMethodInvestmentTag() throws {
        let golden = try Self.loadGolden()
        let entry = try #require(golden["S100VYA0"])
        let segments = try #require(entry["segments"] as? [String: Any])
        let facts = ExtractedBreakdown(dictionary: segments).facts
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEquityMethodInvestments(facts: facts))
        #expect(snapshot.denominatorTag == "InvestmentsInEntitiesAccountedForUsingEquityMethod")
        let logistics = try #require(
            snapshot.rows.first { $0.labelRaw == "LogisticsReportableSegmentsMember" })
        #expect(logistics.amount == 3_888_000_000)
        let subtotal = try #require(
            snapshot.rows.first { $0.labelRaw == "TotalOfReportableSegmentsAndOthersMember" })
        #expect(subtotal.amount == 5_615_000_000)
    }
}
