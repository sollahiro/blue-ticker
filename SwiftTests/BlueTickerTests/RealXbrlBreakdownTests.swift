// 実 EDINET XBRL キャッシュ（analysis_cache）での Stage 6 business 抽出・解決の回帰テスト。
//
// 対象（2026-07-24 実データ検証）:
// - 5108 ブリヂストン S100XRPR: 地域別報告セグメント → IFRS 売上収益の粗い事業区分（タイヤ/その他）
// - 4506 住友ファーマ S100YH3M: 地域別 facts を維持し、製品別表を SegmentInfoLLM へ
// - 6902 デンソー S100Y9T1: 地域別報告セグメント → IFRS 売上収益の事業区分（サーマル等）
//
// キャッシュが無い環境では `.enabled(if:)` で自動 SKIP（`swift test` は鍵なしでも緑）。
// live LLM 経路は `XAI_API_KEY` / `XAI_MODEL` があるときだけ実行する。

import Testing
import Foundation
@testable import BlueTickerCore

private actor RealXbrlMockChat: ChatCompleting {
    private let responseJSON: [String: Any]?
    private(set) var callCount = 0
    private(set) var lastSchemaName: String?

    init(responseJSON: [String: Any]?) {
        self.responseJSON = responseJSON
    }

    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        callCount += 1
        lastSchemaName = schemaName
        guard let responseJSON else { throw ChatCompletionError.emptyContent }
        return try JSONSerialization.data(withJSONObject: responseJSON)
    }

    func timesCalled() async -> Int { callCount }
    func schemaName() async -> String? { lastSchemaName }
}

@Suite struct RealXbrlBreakdownExtractionTests {

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

    // MARK: - ブリヂストン S100XRPR

    @Test(.enabled(if: cacheAvailable("S100XRPR"), "XBRL cache S100XRPR not available"))
    func bridgestoneExtractsIFRSRevenueBusinessRowsAndFootnotes() throws {
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XRPR"))

        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("タイヤ"))
        #expect(joined.contains("その他"))
        // 脚注段落（表の外）が候補に載ること
        #expect(joined.contains("ソリューション"))
        #expect(joined.contains("化工品"))
        #expect(joined.contains("多角化"))
        // 収益種類だけの分解ではない
        #expect(!BreakdownExtractor.isRevenueTypeOnlyDecomposition(result.tables))
    }

    // MARK: - デンソー S100Y9T1

    @Test(.enabled(if: cacheAvailable("S100Y9T1"), "XBRL cache S100Y9T1 not available"))
    func densoExtractsIFRSRevenueBusinessSystemRows() throws {
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100Y9T1"))

        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("サーマル"))
        #expect(joined.contains("パワトレイン"))
        #expect(joined.contains("モビリティ"))
        #expect(!BreakdownExtractor.isRevenueTypeOnlyDecomposition(result.tables))
        // issue #157: 売上マーカーが無くても事業ヒントで実質分解と判定され swap 済み
        #expect(!BreakdownExtractor.tablesContainSalesEquivalent(result.tables))
        #expect(BreakdownExtractor.tablesContainSubstantiveRevenueBreakdown(
            result.tables, relativeTo: [
                BreakdownTable(
                    heading: "セグメント情報",
                    markdown: "| 外部顧客への売上収益 | 7539975 |",
                    period: nil
                ),
            ]))
    }

    // MARK: - 住友ファーマ S100YH3M

    @Test(.enabled(if: cacheAvailable("S100YH3M"), "XBRL cache S100YH3M not available"))
    func sumitomoKeepsGeographyFactsAndProductTablesWithoutRevenueTypeSwap() throws {
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YH3M"))

        // IFRS 売上収益は製商品/知的財産の種類分解 → swap せず geography facts を維持
        #expect(result.method == "xbrl_facts")
        #expect(!result.facts.isEmpty)
        #expect(result.tables.first?.heading == "セグメント情報")

        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("ラツーダ") || joined.contains("オルゴビクス") || joined.contains("製品"))

        let rr = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: Self.xbrlDir("S100YH3M"))
        #expect(rr.method == "html_table")
        #expect(BreakdownExtractor.isRevenueTypeOnlyDecomposition(rr.tables))
    }

    // MARK: - ネクソン S100XSM4（2026-07-24）

    @Test(.enabled(if: cacheAvailable("S100XSM4"), "XBRL cache S100XSM4 not available"))
    func nexonKeepsGeographyFactsButExposesProductRevenueTable() throws {
        // 報告セグメントは Korea/Japan/China/NorthAmerica（地域）。
        // ゲーム課金・ロイヤリティ等の製品別はセグメント注記内の別表にあり、
        // 収益認識注記は無い → swap せず facts を残しつつ tables に製品別を載せる。
        // 後段 SegmentInfoLLM が地域表より製品別表を優先する。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XSM4"))
        #expect(result.method == "xbrl_facts")
        let members = Set(result.facts.compactMap { $0.dimensions["OperatingSegmentsAxis"] })
        #expect(members.contains("KoreaReportableSegmentMember"))
        #expect(members.contains("JapanReportableSegmentMember"))
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("ゲーム課金") || joined.contains("ゲームコンテンツ"))
        #expect(joined.contains("ロイヤリティ"))
        let rr = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: Self.xbrlDir("S100XSM4"))
        #expect(rr.method == "not_found")
    }

    // MARK: - メルカリ S100WQDW（2026-07-25）

    @Test(.enabled(if: cacheAvailable("S100WQDW"), "XBRL cache S100WQDW not available"))
    func mercariKeepsGeographyFactsAndMarketplaceMatrixWithoutRevenueStubSwap() throws {
        // 報告セグメントは Japan Region / US（地域）。Marketplace/Fintech/その他の事業別は
        // セグメント注記内のマトリクスにあり、IFRS 売上収益注記はポインタ＋契約負債表のみ。
        // RR へ無条件 swap すると製品表を失う → facts+tables を残し SegmentInfoLLM へ。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100WQDW"))
        #expect(result.method == "xbrl_facts")
        let members = Set(result.facts.compactMap { $0.dimensions["OperatingSegmentsAxis"] })
        #expect(members.contains("JapanRegionReportableSegmentMember"))
        #expect(members.contains("USReportableSegmentMember"))
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("Marketplace"))
        #expect(joined.contains("Fintech"))
        #expect(joined.contains("その他"))
        let rr = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: Self.xbrlDir("S100WQDW"))
        #expect(rr.method == "html_table")
        #expect(!BreakdownExtractor.tablesContainSalesEquivalent(rr.tables))
        #expect(!BreakdownExtractor.tablesContainSubstantiveRevenueBreakdown(
            rr.tables, relativeTo: result.tables))
        // swap していないこと（見出しが収益認識関係になっていない）
        #expect(result.tables.first?.heading != BreakdownExtractor.revenueRecognitionHeading)
    }

    // MARK: - アサヒ S100VHC1（2026-07-24）

    @Test(.enabled(if: cacheAvailable("S100VHC1"), "XBRL cache S100VHC1 not available"))
    func asahiSwapsGeographySegmentsToIFRSRevenueProductMatrix() throws {
        // 報告セグメントは Japan/Europe/Oceania/SoutheastAsia（地域）。
        // 酒類/飲料/食品・薬品の製品別は IFRS 売上収益注記のマトリクス（列=製品、行=地域）。
        // Oceania を地域キーワードに含めないと allMembersAreGeography が false になり swap できない。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100VHC1"))
        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("酒類製造・販売") || joined.contains("酒類"))
        #expect(joined.contains("飲料製造・販売") || joined.contains("飲料"))
        #expect(joined.contains("食品") && joined.contains("薬品"))
        #expect(!BreakdownExtractor.isRevenueTypeOnlyDecomposition(result.tables))
    }

    // MARK: - 三菱商事 / あおぞら / 三井住友トラスト（2026-07-24）

    @Test(.enabled(if: cacheAvailable("S100YB25"), "XBRL cache S100YB25 not available"))
    func mitsubishiExtractsRevenue2BusinessGroups() throws {
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB25"))
        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("顧客との契約から認識した収益"))
        #expect(joined.contains("地球環境") || joined.contains("マテリアル") || joined.contains("金属資源"))
    }

    @Test(.enabled(if: cacheAvailable("S100YCRO"), "XBRL cache S100YCRO not available"))
    func aozoraExtractsProductOrServiceOrdinaryRevenue() throws {
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YCRO"))
        #expect(!result.tables.isEmpty)
        #expect(result.tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }))
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("貸出業務"))
        #expect(joined.contains("経常収益"))
    }

    @Test(.enabled(if: cacheAvailable("S100YBGM"), "XBRL cache S100YBGM not available"))
    func sumitomoTrustExtractsSubstantialGrossBusinessProfitBySegment() throws {
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YBGM"))
        #expect(!result.tables.isEmpty)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("実質業務粗利益"))
        #expect(joined.contains("個人") && joined.contains("法人"))
        #expect(BreakdownExtractor.tablesContainSalesEquivalent(result.tables))
    }

    // MARK: - エーザイ S100YB05（2026-07-25）

    @Test(.enabled(if: cacheAvailable("S100YB05"), "XBRL cache S100YB05 not available"))
    func eisaiKeepsGeographyFactsAndExposesNeurologyOncologyProductTable() throws {
        // 報告セグメントは Japan/Americas/China/EMEA/EastAsiaGlobalSouth（地域）。
        // ニューロロジー/オンコロジー領域製品は InformationAboutProductsAndServicesIFRS 側。
        // IFRS 売上収益注記は医薬品販売/ライセンスの種類分解 → swap せず facts+製品表を残し
        // SegmentInfoLLM へ（住友ファーマ型）。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB05"))
        #expect(result.method == "xbrl_facts")
        let members = Set(result.facts.compactMap { $0.dimensions["OperatingSegmentsAxis"] })
        #expect(members.contains("EMEAReportableSegmentMember"))
        #expect(members.contains("JapanReportableSegmentMember"))
        #expect(result.tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }))
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("ニューロロジー"))
        #expect(joined.contains("オンコロジー"))
        let rr = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: Self.xbrlDir("S100YB05"))
        #expect(rr.method == "html_table")
        #expect(BreakdownExtractor.isRevenueTypeOnlyDecomposition(rr.tables))
        // geography 判定が通ること（EMEA キーワード欠落の回帰）
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: 825_378_000_000))
        #expect(snap.axis == "geography")
        #expect(snap.needsReview == false)
    }

    // MARK: - オリックス S100YG5L（2026-07-25、issue #103）

    @Test(.enabled(if: cacheAvailable("S100YG5L"), "XBRL cache S100YG5L not available"))
    func orixChainsCurrentPeriodBusinessSegmentTableAcrossColumnViews() throws {
        // issue #103 の回帰: US-GAAP の巨大注記内で「事業別収益(前期)→地域別収益(前期)→
        // 事業別収益(当期)→地域別収益(当期)」の4表が連続するが、列見出し（事業名/地域名）が
        // 表ごとに異なるため headerRowsMatch のみでは前期の1表で打ち切られ、当期表に
        // 到達できなかった（修正前の実データ検証: 候補4件、全て前期/比較のみで当期の
        // 事業別セグメント表が1件も無かった）。行ラベル（収益・利益等）の Jaccard 一致を
        // 追加条件にしたことで当期表まで到達できることを実データで確認する。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YG5L"))
        #expect(result.method == "html_table")
        let currentTables = result.tables.filter { $0.period == "当期" }
        #expect(!currentTables.isEmpty)
        let joined = currentTables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("法人営業"))
        #expect(joined.contains("銀行・クレジット") || joined.contains("輸送機器"))
    }
}

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

    /// 実抽出結果の当期表インデックス（タイヤ/サーマルを含む最初の当期表）。無ければ 0。
    private static func preferredTableIndex(_ tables: [BreakdownTable], containing needle: String) -> Int {
        if let i = tables.firstIndex(where: { $0.period == "当期" && $0.markdown.contains(needle) }) {
            return i
        }
        if let i = tables.firstIndex(where: { $0.markdown.contains(needle) }) {
            return i
        }
        return 0
    }

    @Test(.enabled(if: cacheAvailable("S100XRPR"), "XBRL cache S100XRPR not available"))
    func bridgestoneResolvesViaRevenueRecognitionLLM() async throws {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XRPR"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "タイヤ")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "タイヤ", "amount": 4_146_337, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 283_115, "profit": NSNull(), "row_kind": "segment"],
                ["label": "外部収益 合計", "amount": 4_429_452, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "注1タイヤ＝ソリューション、注2その他＝化工品・多角化",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 4_429_452_000_000.0

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(await client.schemaName() == "revenue_recognition_breakdown")
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("タイヤ"))
        #expect(labels.contains("その他"))
        #expect(audit?.notes.contains("化工品") == true || audit?.notes.contains("ソリューション") == true)
        #expect(await client.timesCalled() == 1)
    }

    @Test(.enabled(if: cacheAvailable("S100Y9T1"), "XBRL cache S100Y9T1 not available"))
    func densoResolvesViaRevenueRecognitionLLM() async throws {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100Y9T1"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "サーマル")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": false,
            // segment 合計が連結売上と整合するよう実額を全行入れる（分母チェック 0.90–1.10）
            "rows": [
                ["label": "サーマルシステム", "amount": 1_780_351, "profit": NSNull(), "row_kind": "segment"],
                ["label": "パワトレインシステム", "amount": 1_479_737, "profit": NSNull(), "row_kind": "segment"],
                ["label": "モビリティエレクトロニクス", "amount": 2_198_663, "profit": NSNull(), "row_kind": "segment"],
                ["label": "エレクトリフィケーションシステム", "amount": 1_433_456, "profit": NSNull(), "row_kind": "segment"],
                ["label": "先進デバイス", "amount": 390_274, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 108_587, "profit": NSNull(), "row_kind": "segment"],
                ["label": "非車載事業分野", "amount": 148_907, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 7_539_975, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "製品系統別分解表を採用",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 7_539_975_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("サーマルシステム"))
        #expect(labels.contains("パワトレインシステム"))
        #expect(labels.contains("モビリティエレクトロニクス"))
        #expect(await client.timesCalled() == 1)
    }

    @Test(.enabled(if: cacheAvailable("S100YH3M"), "XBRL cache S100YH3M not available"))
    func sumitomoResolvesViaSegmentInfoLLMFromProductTable() async throws {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YH3M"))
        #expect(segments.method == "xbrl_facts")
        #expect(!segments.tables.isEmpty)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "ラツーダ")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当連結会計年度",
            "profit_disclosed": false,
            // 分母整合性のため segment 合計≈連結売上。ラベル存在だけを実XBRL回帰で見る。
            "rows": [
                ["label": "ラツーダ（非定型抗精神病薬）", "amount": 13_694, "profit": NSNull(), "row_kind": "segment"],
                ["label": "オルゴビクス（進行性前立腺がん治療剤）", "amount": 155_017, "profit": NSNull(), "row_kind": "segment"],
                ["label": "ジェムテサ（過活動膀胱治療剤）", "amount": 95_986, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他製品等", "amount": 188_597, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 453_294, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "製品及びサービスごとの情報を採用",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 453_294_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(await client.schemaName() == "segment_info_breakdown")
        #expect(snapshot?.axis == "business")
        let labels = snapshot?.rows.map(\.labelRaw).joined(separator: " ") ?? ""
        #expect(labels.contains("ラツーダ"))
        #expect(labels.contains("オルゴビクス"))
        #expect(await client.timesCalled() == 1)
    }

    @Test(.enabled(if: cacheAvailable("S100YB05"), "XBRL cache S100YB05 not available"))
    func eisaiResolvesViaSegmentInfoLLMFromNeurologyOncologyTable() async throws {
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB05"))
        #expect(segments.method == "xbrl_facts")
        #expect(segments.tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }))

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "ニューロロジー")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当連結会計年度",
            "profit_disclosed": false,
            "rows": [
                ["label": "ニューロロジー領域製品", "amount": 260_568, "profit": NSNull(), "row_kind": "segment"],
                ["label": "オンコロジー領域製品", "amount": 362_668, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 202_142, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 825_378, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "主要な製品に関する情報を採用",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 825_378_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(await client.schemaName() == "segment_info_breakdown")
        #expect(snapshot?.axis == "business")
        #expect(snapshot?.needsReview == false)
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("ニューロロジー領域製品"))
        #expect(labels.contains("オンコロジー領域製品"))
        #expect(labels.contains("その他"))
        #expect(await client.timesCalled() == 1)
    }
}

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
        let endpoint = try #require(LLMClientLoader.resolveEndpoint())
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
