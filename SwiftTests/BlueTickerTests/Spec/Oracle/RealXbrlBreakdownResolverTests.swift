// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳回帰（SPEC_ORACLE の L1 実行器）。
// 対象企業は各 @Test にハードコード。html_table は Fake Jev 列スタブ。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlBreakdownResolverTests {

    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する。
    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func resolvedLabels(_ snapshot: BreakdownSnapshot?) -> Set<String> {
        Set(
            (snapshot?.rows ?? []).flatMap { row -> [String] in
                [row.category, row.categoryGroup, row.labelRaw, row.label].compactMap { $0 }
            })
    }

    @Test func bridgestoneResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100XRPR") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XRPR"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let sales = 4_429_452_000_000.0

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales,
            columnDecider: FakeRevenueRecognitionColumnDecider(containing: "タイヤ")
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        let labels = Self.resolvedLabels(snapshot)
        #expect(labels.contains("タイヤ"))
        #expect(labels.contains("その他"))
        #expect(audit?.jev != nil)
    }

    @Test func densoResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100Y9T1") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100Y9T1"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let sales = 7_539_975_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales,
            columnDecider: FakeRevenueRecognitionColumnDecider(containing: "サーマルシステム")
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        let labels = Self.resolvedLabels(snapshot)
        #expect(labels.contains("サーマルシステム"))
        #expect(labels.contains("パワトレインシステム"))
        #expect(labels.contains("モビリティエレクトロニクス"))
    }

    @Test func discoResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100YC6I") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YC6I"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let sales = 436_889_000_000.0
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales,
            columnDecider: FakeRevenueRecognitionColumnDecider(containing: "精密加工装置")
        )
        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        let labels = Self.resolvedLabels(snapshot)
        #expect(labels.contains("精密加工装置"))
        #expect(labels.contains("精密加工ツール"))
        let precision: Bool = snapshot?.rows.contains { row in
            (row.categoryGroup == "精密加工装置" || row.labelRaw == "精密加工装置")
                && row.amount == 273_957_000_000
        } == true
        #expect(precision)
    }

    @Test func tokyoElectronResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100YEOO") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YEOO"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let sales = 2_443_533_000_000.0
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales,
            columnDecider: FakeRevenueRecognitionColumnDecider(containing: "新規装置")
        )
        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        let labels = Self.resolvedLabels(snapshot)
        #expect(labels.contains("新規装置"))
        #expect(labels.contains("フィールドソリューション他"))
        #expect(!labels.contains("日本"))
        #expect(!labels.contains("地理的区分"))
        let needsReview: Bool? = snapshot?.needsReview
        let denominator: Double? = snapshot?.denominator
        let expectedDenom: Double = 2_443_533_000_000
        let equipment: Bool = snapshot?.rows.contains { row in
            (row.categoryGroup == "新規装置" || row.labelRaw == "新規装置")
                && row.amount == 1_817_250_000_000
        } == true
        #expect(needsReview == false)
        #expect(denominator == expectedDenom)
        #expect(equipment)
    }

    @Test func mitsubishiBusinessDenominatorKeepsCustomerContractWhenPLRevenueDiffers() async throws {
        guard await Self.ensureAvailable("S100YB25") else { return }
        let dir = Self.xbrlDir("S100YB25")
        // Summary sales は本表 Revenue2IFRS「収益」18,915,995 百万円。
        #expect(BreakdownFinancialsResolver.financialsCanonicalSales(xbrlDir: dir) == 18_915_995_000_000)
        // NotesRevenue2 当期表（単位：百万円）。顧客との契約から認識した収益:
        //   合計列 13,939,592（報告セグメント小計）≠ 連結金額列 13,948,091。
        // その他の源泉から認識した収益 連結金額 4,967,904。合計行 連結金額 18,915,995。
        // product_service 分母は顧客との契約の連結金額 13,948,091。その他の源泉は含めない。
        let denom = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(xbrlDir: dir)
        #expect(denom.value == 13_948_091_000_000)
        #expect(denom.tag == "llm_table_subtotal")
    }

    @Test func mitsubishiResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100YB25") else { return }
        let dir = Self.xbrlDir("S100YB25")
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: dir)
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let denom = BreakdownFinancialsResolver.breakdownBusinessSalesDenominatorItem(
            xbrlDir: dir, tables: segments.tables)
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: denom.value,
            denominatorTag: denom.tag,
            columnDecider: FakeRevenueRecognitionColumnDecider(containing: "地球環境エネルギー")
        )
        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        // 顧客との契約から認識した収益 × 連結金額。合計列 13,939,592 ではない。
        #expect(snapshot?.denominator == 13_948_091_000_000)
        #expect(snapshot?.denominatorTag == "llm_table_subtotal")
        let labels = Self.resolvedLabels(snapshot)
        #expect(labels.contains("地球環境エネルギー"))
        let slc: Bool = labels.contains("S.L.C.") || labels.contains(where: { $0.contains("S.L.C") })
        #expect(slc)
        #expect(labels.contains("電力ソリューション"))
        let metal: Bool = snapshot?.rows.contains { row in
            (row.categoryGroup == "金属資源" || row.category == "金属資源" || row.labelRaw == "金属資源")
                && row.amount == 1_243_344_000_000
        } == true
        let needsReview: Bool? = snapshot?.needsReview
        #expect(metal)
        #expect(needsReview == false)
    }

    @Test func sumitomoResolvesViaSegmentInfoLLMFromProductTable() async throws {
        guard await Self.ensureAvailable("S100YH3M") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YH3M"))
        #expect(segments.method == "xbrl_facts")
        #expect(!segments.tables.isEmpty)

        let sales = 453_294_000_000.0
        let decider = FakeRevenueRecognitionColumnDecider(containing: "ラツーダ")

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, columnDecider: decider
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        let labels = snapshot?.rows.map(\.labelRaw).joined(separator: " ") ?? ""
        #expect(labels.contains("ラツーダ"))
        #expect(labels.contains("オルゴビクス") || labels.contains("ORGOVYX"))
    }

    @Test func eisaiResolvesViaSegmentInfoLLMFromNeurologyOncologyTable() async throws {
        guard await Self.ensureAvailable("S100YB05") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB05"))
        #expect(segments.method == "xbrl_facts")
        #expect(segments.tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }))

        let sales = 825_378_000_000.0
        let decider = FakeRevenueRecognitionColumnDecider(containing: "ニューロロジー")

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, columnDecider: decider
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        let labels = Self.resolvedLabels(snapshot)
        #expect(labels.contains("ニューロロジー領域製品") || labels.contains(where: { $0.contains("ニューロロジー") }))
        #expect(labels.contains("オンコロジー領域製品") || labels.contains(where: { $0.contains("オンコロジー") }))
    }

    // MARK: - 資生堂 S100XSCU（2026-08-14）

    @Test func shiseidoResolvesGeographicBusinessSegmentsViaSegmentInfoLLM() async throws {
        guard await Self.ensureAvailable("S100XSCU") else { return }
        // 報告セグメント名が「日本事業」「米州事業」等の地域事業ユニット。金額はユーザー確認済み
        // （分母 969,992 百万円と一致）。ラベルが地名に見えるため needs_review は立つが、
        // 中身は事業軸として採用する（本番 segment_info_llm / S100XSCU）。
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XSCU"))
        let joined = segments.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("日本事業"))

        let sales = 969_992_000_000.0
        let decider = FakeRevenueRecognitionColumnDecider(containing: "日本事業")

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, columnDecider: decider
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == breakdownAxisProductService)
        #expect(snapshot?.needsReview == true)
        #expect(snapshot?.warnings.contains("business_label_looks_like_geography") == true)
        let japan = try #require(snapshot?.rows.first { $0.labelRaw.contains("日本") })
        #expect(japan.labelRaw == "日本事業")
        #expect(japan.amount == 295_343_000_000)
        let china = try #require(snapshot?.rows.first { $0.labelRaw.contains("トラベルリテール") })
        #expect(china.amount == 342_244_000_000)
    }

    @Test func asahi2023ResolvesJapanOverseasGeographyViaJev() async throws {
        guard await Self.ensureAvailable("S100QG09") else { return }
        let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: Self.xbrlDir("S100QG09"))
        #expect(geography.method == "html_table")
        let sales = 2_511_108_000_000.0

        let (snapshot, source, audit) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: sales,
            columnDecider: FakeRevenueRecognitionColumnDecider(containing: "1,281,768"),
            fiscalYearEnd: "2023-12-31",
            docID: "S100QG09"
        )

        #expect(source == .geographyLLM)
        #expect(snapshot?.axis == "geography")
        #expect(snapshot?.needsReview == false)
        #expect(snapshot?.denominator == sales)
        #expect(audit?.jev != nil)
        let japan = try #require(snapshot?.rows.first { $0.labelRaw == "日本" })
        #expect(japan.amount == 1_281_768_000_000)
        let overseas = try #require(snapshot?.rows.first { $0.labelRaw == "海外" })
        #expect(overseas.amount == 1_229_340_000_000)
    }

    @Test func konamiBusinessResolvesViaXbrlFactsWithoutLLM() async throws {
        guard await Self.ensureAvailable("S100YKX5") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YKX5"))
        let sales = 493_677_000_000.0

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales
        )

        #expect(source == .xbrlFacts)
        #expect(audit == nil)
        let snap = try #require(snapshot)
        #expect(snap.axis == breakdownAxisProductService)
        #expect(snap.denominatorTag == "NetSalesAndOperatingRevenueFromExternalCustomersIFRS")
        #expect(snap.denominator == sales)
        #expect(snap.denominator / sales < 10)
        #expect(!snap.needsReview)
        let digital = try #require(snap.rows.first {
            $0.labelRaw.contains("DigitalEntertainment") || $0.label == "デジタルエンタテインメント事業"
        })
        #expect(digital.amount == 370_225_000_000)
        #expect(digital.rowKind == "segment")
    }

    /// フジックス S100YHMW: 報告セグメントは日本/アジア。製品別は90％省略で表が無い。
    /// business は geography_only。日本/アジアを product_service に載せない。
    @Test func fujixResolvesBusinessAsGeographyOnly() async throws {
        guard await Self.ensureAvailable("S100YHMW") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YHMW"))
        let method: String = segments.method
        #expect(method == "html_table" || method == "xbrl_facts")
        let joined = segments.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("4,333,990") || joined.contains("4333990"))
        #expect(!joined.contains("ALOFISEL"))

        let sales = 5_474_552_000.0
        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales,
            columnDecider: FakeRevenueRecognitionColumnDecider(containing: "セグメント損失"),
            fiscalYearEnd: "2026-03-31",
            docID: "S100YHMW"
        )

        #expect(snapshot == nil)
        #expect(source == .notFound)
        #expect(audit?.notApplicableReason == breakdownNotApplicableGeographyOnly)
        let reason = BreakdownExtractor.classifyNotApplicableReason(
            segments: segments, consolidatedSales: sales, xbrlDir: Self.xbrlDir("S100YHMW"),
            llmHint: audit?.notApplicableReason)
        #expect(reason == .geographyOnly)
    }

    /// フジックス S100LRPS（FY2021）: 同じ geo-only + 製品省略。sales-matrix 回復はしない。
    @Test func fujixFY2021ResolvesBusinessAsGeographyOnly() async throws {
        guard await Self.ensureAvailable("S100LRPS") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100LRPS"))
        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: 5_830_295_000.0,
            columnDecider: FakeRevenueRecognitionColumnDecider(),
            fiscalYearEnd: "2022-03-31",
            docID: "S100LRPS"
        )
        #expect(snapshot == nil)
        #expect(source == .notFound)
        let reason = BreakdownExtractor.classifyNotApplicableReason(
            segments: segments, consolidatedSales: 5_830_295_000.0,
            xbrlDir: Self.xbrlDir("S100LRPS"), llmHint: audit?.notApplicableReason)
        #expect(reason == .geographyOnly)
    }
}

