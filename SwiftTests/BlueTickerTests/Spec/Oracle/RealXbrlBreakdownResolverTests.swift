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

    /// 7464 S100YJG0 / 7532 S100Z42G: 顧客との契約の外の収益（その他の源泉 /
    /// その他の収益）は `reconciling` 行。segment ＋ reconciling が表の総合計（分母）に一致する。
    /// 三菱商事のように顧客との契約の合計を分母にする表では足さない（上の分母テスト）。
    // source: code=7464 fy_end=2026-03-31 doc_id=S100YJG0 page=56 field=product_service.その他の源泉から生じる収益
    // source: code=7532 fy_end=2026-06-30 doc_id=S100Z42G page=137 field=product_service.その他の収益

    /// 6526 S100R9DF: 「顧客との契約から生ずる収益」は「生じる」の表記揺れで合計行。
    /// 明細（製品売上 / ＮＲＥ売上 / その他）に入れず、明細の合計が分母 192,767 百万円に一致する。
    // source: code=6526 fy_end=2023-03-31 doc_id=S100R9DF page=107 field=product_service.顧客との契約から生ずる収益

    // source: code=4506 fy_end=2026-03-31 doc_id=S100YH3M page=91 field=product_service 医薬品 453,283 / その他 11
    /// 字下げだけの親子（医薬品 → 日本・北米・アジア → 製品）は最上位の 医薬品・その他 の2行に畳む。

    // source: code=6254 fy_end=2026-03-31 doc_id=S100YG4U page=103 field=product_service 単一の製品・サービス 90％超で省略
    // source: code=6592 fy_end=2025-12-31 doc_id=S100XUAX page=116 field=product_service 小型モーターの単一事業で省略
    /// 報告セグメントが地域（Taiwan / UnitedStates を含む）で、製品・サービス別が省略文だけなら
    /// product_service は geography_only の条件をすべて満たす。
    @Test(arguments: ["S100YG4U", "S100XUAX"])
    func geographicSegmentsWithOmittedProductInfo(docID: String) async throws {
        guard await Self.ensureAvailable(docID) else { return }
        let dir = Self.xbrlDir(docID)
        let products = BreakdownExtractor.extractProductServiceInfo(xbrlDir: dir)
        let memberCount = BreakdownExtractor.currentYearReportableOperatingSegmentSalesMemberCount(xbrlDir: dir)
        let geographic = BreakdownExtractor.reportedOperatingSegmentsAreGeographic(xbrlDir: dir)
        let usable = SegmentInfoLLMNormalizer.hasUsableProductOrBusinessTable(products.tables)
        let omission = BreakdownExtractor.productServiceOmissionText(xbrlDir: dir)
        #expect(memberCount >= 2)
        #expect(geographic)
        #expect(usable == false)
        #expect(omission?.contains("記載を省略") == true)
    }

    // MARK: - 資生堂 S100XSCU（2026-08-14）

    @Test func shiseidoResolvesGeographicBusinessSegmentsViaSegmentInfoLLM() async throws {
        guard await Self.ensureAvailable("S100XSCU") else { return }
        // 報告セグメント名が「日本事業」「米州事業」等の地域事業ユニット。金額はユーザー確認済み
        // （分母 969,992 百万円と一致）。ラベルが地名に見えるため needs_review は立つが、
        // 中身は事業軸として採用する（本番 segment_info_llm / S100XSCU）。
        let reportable = BreakdownExtractor.extractReportableSegmentInfo(
            xbrlDir: Self.xbrlDir("S100XSCU"))
        let joined = reportable.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("日本事業"))

        let sales = 969_992_000_000.0
        let decider = FakeRevenueRecognitionColumnDecider(containing: "日本事業")

        let (snapshot, source, _) = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: sales,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: Self.xbrlDir("S100XSCU")),
            segmentInfoDecider: decider
        )

        #expect(source == .segmentInfoLLM || source == .xbrlFacts)
        #expect(snapshot?.axis == breakdownAxisSegment)
        let japan = try #require(snapshot?.rows.first {
            ($0.label ?? $0.labelRaw).contains("日本")
        })
        #expect((japan.label ?? japan.labelRaw).contains("日本"))
        #expect(japan.amount == 295_343_000_000)
        let china = try #require(snapshot?.rows.first {
            ($0.label ?? $0.labelRaw).contains("トラベルリテール")
        })
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

    /// フジックス S100YHMW: 報告セグメントは日本/アジア。製品別は90％省略で表が無い。
    /// business は geography_only。日本/アジアを product_service に載せない。

    /// フジックス S100LRPS（FY2021）: 同じ geo-only + 製品省略。sales-matrix 回復はしない。

    /// Sony 6758 S100W19Q: 報告セグメントは G&NS 等。製品カテゴリ表は product_service。
    // source: code=6758 fy_end=2025-03-31 doc_id=S100W19Q page=152 field=segment.G&NS
    // source: code=6758 fy_end=2025-03-31 doc_id=S100W19Q page=126 field=segment.denominator
    // source: code=6758 fy_end=2025-03-31 doc_id=S100W19Q page=155 field=product_service.デジタルソフトウェア

    /// Sony 6758 FY2021–23: 報告セグメント表（外部顧客）。製品カテゴリー表ではない。
    /// 分母は 売上高及び金融ビジネス収入（全社（共通）の外部売上を含む連結合計）。
    // source: code=6758 fy_end=2024-03-31 doc_id=S100TS7P page=151 field=segment.G&NS
    // source: code=6758 fy_end=2023-03-31 doc_id=S100QZT6 page=144 field=segment.G&NS
    // source: code=6758 fy_end=2022-03-31 doc_id=S100OJ0K page=134 field=segment.G&NS
    @Test(arguments: [
        ("S100TS7P", [4_172_994, 1_594_955, 1_486_717, 2_414_946, 1_503_906, 1_760_731, 75_784] as [Double],
         13_020_768.0),
        ("S100QZT6", [3_538_533, 1_364_815, 1_364_887, 2_436_739, 1_301_481, 1_443_996, 72_338] as [Double],
         11_539_837.0),
        ("S100OJ0K", [2_674_356, 1_100_532, 1_236_399, 2_297_886, 992_200, 1_524_811, 82_264] as [Double],
         9_921_513.0),
    ])
    func sonyPriorYearsUseReportableSegmentTable(
        docID: String, millions: [Double], denominatorMillion: Double
    ) async throws {
        guard await Self.ensureAvailable(docID) else { return }
        let dir = Self.xbrlDir(docID)
        let yen = Financial.millionYen
        let needles: [[String]] = [
            ["G&NS", "ゲーム"], ["音楽"], ["映画"],
            ["ET&S", "EP&S", "エンタテインメント・テクノロジー", "エレクトロニクス"],
            ["I&SS", "イメージング"], ["金融"], ["その他"],
        ]
        let financials = StatementFinancialsResolver.resolve(xbrlDir: dir)
        let coverage = financials?.geographyCoverageSales ?? financials?.sales
        let reportable = BreakdownExtractor.extractReportableSegmentInfo(xbrlDir: dir)
        let (segment, source, _) = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: coverage,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: dir))
        #expect(source == .xbrlFacts)
        let snap = try #require(segment)
        #expect(snap.axis == breakdownAxisSegment)
        #expect(snap.denominator == denominatorMillion * yen)
        for (needle, million) in zip(needles, millions) {
            let row = try #require(snap.rows.first { row in
                let blob = (row.label ?? "") + row.labelRaw
                return row.rowKind == "segment" && needle.contains(where: { blob.contains($0) })
            })
            #expect(row.amount == million * yen)
        }
        #expect(snap.rows.filter { $0.rowKind == "segment" }.count == 7)
    }

    /// Takeda 4502 S100YB5L: 単一セグメント 医薬品事業。製品は収益の分解。
    // source: code=4502 fy_end=2026-03-31 doc_id=S100YB5L page=169 field=segment.医薬品事業
    // source: code=4502 fy_end=2026-03-31 doc_id=S100YB5L page=170 field=product_service.ENTYVIO
    // source: code=4502 fy_end=2026-03-31 doc_id=S100YB5L page=146 field=employees.医薬品事業

    /// Sony 6758 最新 S100YE2C: 旧 product_service の xbrl_facts セグメント行は segment へ移す。
    // source: code=6758 fy_end=2026-03-31 doc_id=S100YE2C page=152 field=product_service.not_reportable_segment_facts

    /// 電通 4324 S100XS0O: 報告セグメントは日本 / Americas / EMEA / APAC。
    /// IFRS `InformationAboutGeographicalAreasIFRSTextBlock`「(4) 地域に関する情報」は
    /// ①外部顧客からの売上収益が米国の重要性開示のみ、②非流動資産表。売上の地域表は無い。
    /// 抽出は not_found。公開 geography は same_as: segment。
    // source: code=4324 fy_end=2025-12-31 doc_id=S100XS0O page=0 field=geography
    @Test func dentsuS100XS0OGeographyIsSameAsGeographicSegments() async throws {
        guard await Self.ensureAvailable("S100XS0O") else { return }
        let dir = Self.xbrlDir("S100XS0O")
        let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: dir)
        #expect(geography.method == "not_found")
        #expect(geography.tables.isEmpty)
        #expect(geography.facts.isEmpty)

        let reportable = BreakdownExtractor.extractReportableSegmentInfo(xbrlDir: dir)
        let members = SegmentBreakdownResolver.currentSegmentMembers(in: reportable.facts)
        #expect(BreakdownNormalizer.allMembersAreGeography(members))
        let pattern = await SegmentNotePatternClassifier.classify(
            axis: .geography,
            signals: SegmentNotePatternSignals(
                reportableMemberCount: members.count,
                hasDedicatedSingleSegmentTag: false,
                hasReportableSegmentTable: !reportable.tables.isEmpty,
                hasRelatedInfoTable: false,
                reportableMembersAreGeographic: true,
                prose: BreakdownExtractor.segmentNotePatternProse(xbrlDir: dir)),
            docID: "S100XS0O",
            decider: nil)
        #expect(pattern.classification == .omittedSameAsSegment)
        #expect(pattern.source == SegmentNotePatternClassifier.deterministicSource)
        let sameAs = SegmentBreakdownResolver.sameAsSnapshot(axis: breakdownAxisGeography)
        #expect(sameAs.sameAs == breakdownAxisSegment)
        #expect(sameAs.rows.isEmpty)
        #expect(sameAs.sourceKind == breakdownSourceSameAs)

        let sales = 1_435_245_000_000.0
        let (segment, source, _) = await SegmentBreakdownResolver.resolve(
            reportable: reportable, consolidatedSales: sales,
            labelsByTag: XBRLUtils.loadLabelsByTag(in: dir))
        #expect(source == .xbrlFacts)
        let snap = try #require(segment)
        #expect(snap.axis == breakdownAxisSegment)
        #expect(snap.denominator == sales)
        #expect(snap.denominatorTag == "Revenue2IFRS")
        let expected: [(needle: String, amount: Double)] = [
            ("Japan", 608_310_000_000),
            ("Americas", 369_666_000_000),
            ("EMEA", 338_401_000_000),
            ("APAC", 112_199_000_000),
        ]
        let segmentRows = snap.rows.filter { $0.rowKind == "segment" }
        #expect(segmentRows.count == 4)
        for (needle, amount) in expected {
            let row = try #require(segmentRows.first { row in
                row.labelRaw.contains(needle) || (row.label ?? "").contains(needle)
                    || (needle == "Japan" && (row.label ?? "").contains("日本"))
            })
            #expect(row.amount == amount)
            #expect(row.segmentBasis == breakdownSegmentBasisGeographic)
        }

        let analysisCache = Self.xbrlRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ctx = BltServerContext(
            apiKey: ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"] ?? "test",
            cacheDir: analysisCache)
        switch await ctx.resolveGeographyBreakdown(docID: "S100XS0O") {
        case .resolved(let payload, let geoSource, _, _):
            #expect(geoSource == breakdownSourceSameAs)
            #expect(payload.axis == breakdownAxisGeography)
            #expect(payload.sameAs == breakdownAxisSegment)
            #expect(payload.rows.isEmpty)
        case .notApplicable(let reason, _):
            Issue.record("geography same_as expected, got not_applicable \(reason)")
        case .failed:
            Issue.record("geography same_as expected, got failed")
        }
    }
}

