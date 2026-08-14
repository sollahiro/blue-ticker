// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳（business/geography breakdown）
// 抽出・解決の回帰テスト。`smoke/` 配下のフィクスチャは使わず、対象企業は各 @Test 関数に
// 個別ハードコードしている（5 @Suite: Extraction / EmployeesRD / GoodwillSmoke+Golden / Resolver / LiveLLM。
// 一覧は本ファイルの @Test 関数名、または `swift test --filter RealXbrlBreakdown --list-tests`）。
//
// `BLT_EDINET_API_KEY`（CI の swift-macos/swift-linux ジョブは secrets 経由で設定済み）が
// あれば `SmokeCacheSupport.ensureCached` で不足キャッシュを自動取得して実データのまま検証する。
// 抽出ロジック（Extraction）・モック応答での resolver 検証（Resolver）は LLM 呼び出しを
// 伴わないため、鍵さえあれば CI で実行できる。鍵も既存キャッシュも無い環境ではテスト内で
// SKIP する（`swift test` は緑のまま）。
// live LLM 経路（LiveLLM）のみ `XAI_API_KEY` / `XAI_MODEL` があるときだけ実行する。

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

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する。
    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    // MARK: - ブリヂストン S100XRPR

    @Test func bridgestoneExtractsIFRSRevenueBusinessRowsAndFootnotes() async throws {
        guard await Self.ensureAvailable("S100XRPR") else { return }
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

    @Test func densoExtractsIFRSRevenueBusinessSystemRows() async throws {
        guard await Self.ensureAvailable("S100Y9T1") else { return }
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

    @Test func sumitomoKeepsGeographyFactsAndProductTablesWithoutRevenueTypeSwap() async throws {
        guard await Self.ensureAvailable("S100YH3M") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YH3M"))

        // IFRS 売上収益は製商品/知的財産の種類分解 → swap せず geography facts を維持
        #expect(result.method == "xbrl_facts")
        #expect(!result.facts.isEmpty)
        // 製品・サービス別情報ブロックがあれば報告セグメント表より先に置かれる
        // （extractSegmentInfo の設計、実データ 2026-07-31 時点で本書類に当該ブロックが追加された）。
        #expect(result.tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }))
        #expect(result.tables.first?.heading == BreakdownExtractor.productOrServiceHeading
            || result.tables.first?.heading == "セグメント情報")

        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("ラツーダ") || joined.contains("オルゴビクス") || joined.contains("製品"))

        let rr = BreakdownExtractor.extractRevenueRecognitionInfo(xbrlDir: Self.xbrlDir("S100YH3M"))
        #expect(rr.method == "html_table")
        #expect(BreakdownExtractor.isRevenueTypeOnlyDecomposition(rr.tables))
    }

    // MARK: - ネクソン S100XSM4（2026-07-24）

    @Test func nexonKeepsGeographyFactsButExposesProductRevenueTable() async throws {
        guard await Self.ensureAvailable("S100XSM4") else { return }
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

    @Test func mercariKeepsGeographyFactsAndMarketplaceMatrixWithoutRevenueStubSwap() async throws {
        guard await Self.ensureAvailable("S100WQDW") else { return }
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

    // MARK: - レーザーテック S100JRT9 geography（2026-08-14）

    @Test func lasertecGeographyDedicatedContextRefsLabelPriorThenCurrent() async throws {
        guard await Self.ensureAvailable("S100JRT9") else { return }
        // J-GAAP 関連情報: 「当連結会計年度」見出しは地域売上 TextBlock の外にあり、
        // 表グリッドにも期ラベルが無い。専用 TextBlock が Prior1YearDuration /
        // CurrentYearDuration に分かれるため、contextRef から period を付ける
        // （`geographyDedicatedDualContextBlocksGetPriorThenCurrent` と同型。
        // 本番 LLM 監査は両候補 period=前期と記録していたが、現行抽出では改善済み）。
        let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: Self.xbrlDir("S100JRT9"))
        #expect(result.method == "html_table")
        let regionTables = result.tables.filter {
            $0.markdown.contains("日本") && $0.markdown.contains("台湾")
                && $0.markdown.contains("韓国")
        }
        #expect(regionTables.count >= 2)
        let prior = try #require(regionTables.first {
            $0.markdown.contains("28,769,951") || $0.markdown.contains("28769951")
        })
        let current = try #require(regionTables.first {
            $0.markdown.contains("42,572,915") || $0.markdown.contains("42572915")
        })
        #expect(prior.period == "前期")
        #expect(current.period == "当期")
        #expect(current.markdown.contains("7,182,133") || current.markdown.contains("7182133"))
    }

    // MARK: - アサヒ S100QG09 geography（2023-03-29、本番 unknown）

    @Test func asahi2023GeographyExtractionFindsJapanOverseasRevenueTable() async throws {
        guard await Self.ensureAvailable("S100QG09") else { return }
        // IFRS「地域に関する情報」の対外部売上収益。日本/海外（うち豪州は内数）。
        // 合計 2,511,108 百万円は当該年度の連結売上と一致。本番は tables あり・
        // llm_audit 無しの unknown（LLM 呼び出し失敗）で、抽出欠測ではない。
        let result = BreakdownExtractor.extractGeographyInfo(xbrlDir: Self.xbrlDir("S100QG09"))
        #expect(result.method == "html_table")
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("日本"))
        #expect(joined.contains("海外"))
        #expect(joined.contains("1,281,768") || joined.contains("1281768"))
        #expect(joined.contains("2,511,108") || joined.contains("2511108"))
    }

    // MARK: - 資生堂 S100XSCU business（2026-08-14）

    @Test func shiseidoExtractsGeographicNamedBusinessSegmentTable() async throws {
        guard await Self.ensureAvailable("S100XSCU") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XSCU"))
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("日本事業"))
        #expect(joined.contains("中国") && joined.contains("トラベルリテール"))
        #expect(joined.contains("米州事業"))
        #expect(joined.contains("欧州事業"))
    }

    // MARK: - アサヒ S100VHC1（2026-07-24）

    @Test func asahiSwapsGeographySegmentsToIFRSRevenueProductMatrix() async throws {
        guard await Self.ensureAvailable("S100VHC1") else { return }
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

    @Test func mitsubishiExtractsRevenue2BusinessGroups() async throws {
        guard await Self.ensureAvailable("S100YB25") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB25"))
        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("顧客との契約から認識した収益"))
        #expect(joined.contains("地球環境") || joined.contains("マテリアル") || joined.contains("金属資源"))
    }

    @Test func aozoraExtractsProductOrServiceOrdinaryRevenue() async throws {
        guard await Self.ensureAvailable("S100YCRO") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YCRO"))
        #expect(!result.tables.isEmpty)
        #expect(result.tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }))
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("貸出業務"))
        #expect(joined.contains("経常収益"))
    }

    @Test func sumitomoTrustExtractsSubstantialGrossBusinessProfitBySegment() async throws {
        guard await Self.ensureAvailable("S100YBGM") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YBGM"))
        #expect(!result.tables.isEmpty)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("実質業務粗利益"))
        #expect(joined.contains("個人") && joined.contains("法人"))
        #expect(BreakdownExtractor.tablesContainSalesEquivalent(result.tables))
    }

    // MARK: - エーザイ S100YB05（2026-07-25）

    @Test func eisaiKeepsGeographyFactsAndExposesNeurologyOncologyProductTable() async throws {
        guard await Self.ensureAvailable("S100YB05") else { return }
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

    // MARK: - 武田 S100YB5L（2026-08-14）

    @Test func takedaMergesPageSplitProductByProductRevenueTables() async throws {
        guard await Self.ensureAvailable("S100YB5L") else { return }
        // ビジネスエリア別・製品別売上が改ページで2つの <table> に割れる。
        // 前半（ENTYVIO / 消化器系疾患 / 希少疾患）と後半（血漿分画 / 売上収益合計）が
        // 同一候補に載ること。LLM に複数表選択を頼まない。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB5L"))
        #expect(result.method == "html_table")
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("ENTYVIO"))
        #expect(joined.contains("消化器系疾患"))
        #expect(joined.contains("血漿分画"))
        #expect(joined.contains("売上収益合計"))
        #expect(joined.contains("4,505,720") || joined.contains("4505720"))
        let merged = result.tables.filter {
            $0.markdown.contains("ENTYVIO") && $0.markdown.contains("売上収益合計")
        }
        #expect(!merged.isEmpty)
    }

    // MARK: - 任天堂 S100Y9NX（2026-08-14）

    @Test func nintendoProductOrServiceDualContextGetsPriorThenCurrent() async throws {
        guard await Self.ensureAvailable("S100Y9NX") else { return }
        // 製品・サービス別専用タグが Prior1YearDuration / CurrentYearDuration に分かれ、
        // HTML に期間見出しが無い。contextRef を period にしないと両方「前期」になる。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100Y9NX"))
        let product = result.tables.filter { $0.heading == BreakdownExtractor.productOrServiceHeading }
        #expect(product.count == 2)
        #expect(product.map(\.period) == ["前期", "当期"])
        #expect(product[0].markdown.contains("1,164,922") || product[0].markdown.contains("1164922"))
        #expect(product[1].markdown.contains("2,313,051") || product[1].markdown.contains("2313051"))
    }

    // MARK: - オリックス S100YG5L（2026-07-25、issue #103）

    @Test func orixChainsCurrentPeriodBusinessSegmentTableAcrossColumnViews() async throws {
        guard await Self.ensureAvailable("S100YG5L") else { return }
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

// 実 EDINET XBRL キャッシュでの 内訳取り込み employees/research_and_development 軸の回帰テスト。
// 2026-08-01 監査指摘: `CorporateSharedMember`（本社機能等の少額バケツ）を "subtotal" に分類すると
// 合計チェックから除外され、これを含めないと sum(segment) が常に total を下回るため
// 5%乖離警告が恒常的な誤検知になる（needs_review=true が固定化し再ingestループになる）。
// 京セラ S100TSIJ は実データでこの境界（乖離ちょうど4.98%）を踏む代表例。
@Suite struct RealXbrlEmployeesRDBreakdownTests {

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

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    // MARK: - 京セラ S100TSIJ（2026-08-01）

    @Test func kyoceraEmployeesReconcilesCorporateSharedAsAdditiveNotSubtotal() async throws {
        guard await Self.ensureAvailable("S100TSIJ") else { return }
        let xbrlDir = Self.xbrlDir("S100TSIJ")
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)

        // 全社合計は 財務取り込み 計算済みの値を想定した固定値（実データ: 73,165人）。
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 73_165, axis: "employees", labelsByTag: labelsByTag))

        #expect(snapshot.axis == "employees")
        #expect(snapshot.denominator == 73_165)
        // CorporateShared を含めた実際の内訳合計が総数に一致するため、誤検知の
        // needs_review が立たないこと（監査指摘の核心）。
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)

        let corporateShared = try #require(
            snapshot.rows.first { $0.labelRaw == "CorporateSharedMember" })
        // 代替総合計（subtotal）ではなく、合計に加算される少額バケツ（reconciling）として
        // 分類されること。誤って "subtotal" のままだと表示側が総数を3,645人と誤認する
        // （監査指摘 #3、served payload への波及）。
        #expect(corporateShared.rowKind == "reconciling")
        #expect(corporateShared.amount == 3_645)

        let segmentSum = snapshot.rows.map(\.amount).reduce(0, +)
        #expect(segmentSum == snapshot.denominator)

        // ラベルリンクベースの日本語ラベルが解決されること（提出書類の label linkbase 実データ確認）。
        // CorporateSharedMember は提出書類側の拡張ラベルが無く未解決（label == nil、公開層で
        // labelRaw へフォールバック）。
        let components = try #require(
            snapshot.rows.first { $0.labelRaw == "ComponentsReportableSegmentsMember" })
        #expect(components.label == "コンポーネント")
        #expect(corporateShared.label == nil)
    }

    @Test func kyoceraResearchAndDevelopmentResolvesWithoutWarning() async throws {
        guard await Self.ensureAvailable("S100TSIJ") else { return }
        let xbrlDir = Self.xbrlDir("S100TSIJ")
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)

        let snapshot = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 132_502_000_000, axis: "research_and_development",
                labelsByTag: labelsByTag))

        #expect(snapshot.axis == "research_and_development")
        #expect(snapshot.needsReview == false)
        let labels = Set(snapshot.rows.map(\.labelRaw))
        #expect(labels.contains("ComponentsReportableSegmentsMember"))
        #expect(labels.contains("DevicesAndModulesReportableSegmentsMember"))
        #expect(labels.contains("OtherReportableSegmentsMember"))

        let devicesAndModules = try #require(
            snapshot.rows.first { $0.labelRaw == "DevicesAndModulesReportableSegmentsMember" })
        #expect(devicesAndModules.label == "デバイス・モジュール")
    }

    // MARK: - employees/research_and_development 軸 実データゴールデン（2026-08-03、10社レビュー）
    //
    // ユーザーが10社（日経225）のemployees/research_and_development軸抽出結果を実データで
    // 目視確認済み（生XBRLと突き合わせ、SCREEN HD「上記セグメント以外9,151」・日東電工
    // 「全社技術部門10,725」等、注記本文にのみ存在しXBRL dimensionタグが無い値の欠測を確認）。
    // needs_review=false の行のみ確認対象とし、正しさが確認できた絶対値をgolden化する
    // （needs_review=true の行は開示側の構造的欠測であり別途対応、docs/breakdown.md）。
    // 割合ではなく実額（人数・円）で確認したユーザー指摘に合わせ、golden も実額のみを見る。

    private static func employeesFactsAndLabels(
        _ docID: String
    ) -> (facts: [BreakdownFact], labels: [String: String]) {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        return (facts, XBRLUtils.loadLabelsByTag(in: dir))
    }

    @Test func yokogawaEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VY8X") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VY8X")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 17_670, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 17_670)
        let empControl = try #require(
            emp.rows.first { $0.labelRaw == "IndustrialAutomationAndControlReportableSegmentsMember" })
        #expect(empControl.amount == 16_781)
        #expect(empControl.label == "制御")

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 32_061_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let rdControl = try #require(
            rd.rows.first { $0.labelRaw == "IndustrialAutomationAndControlReportableSegmentsMember" })
        #expect(rdControl.amount == 28_835_000_000)
        #expect(rdControl.label == "制御")
    }

    @Test func mitsubishiMotorsEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VZMJ") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VZMJ")

        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 28_572, axis: "employees", labelsByTag: labels))
        #expect(snapshot.needsReview == false)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == 28_572)
        let car = try #require(snapshot.rows.first { $0.labelRaw == "CarSegmentMember" })
        #expect(car.amount == 28_384)
        #expect(car.label == "自動車事業")
        let financial = try #require(snapshot.rows.first { $0.labelRaw == "FinancialSegmentMember" })
        #expect(financial.amount == 188)
        #expect(financial.label == "金融事業")
    }

    @Test func itochuEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VYN4") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYN4")

        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 115_089, axis: "employees", labelsByTag: labels))
        #expect(snapshot.needsReview == false)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == 115_089)
        let food = try #require(snapshot.rows.first { $0.labelRaw == "FoodReportableSegmentMember" })
        #expect(food.amount == 31_380)
        #expect(food.label == "食料")
    }

    @Test func nittoDenkoEmployeesMatchesDisclosedSegmentTotalsRDStaysNeedsReview() async throws {
        guard await Self.ensureAvailable("S100VYH3") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYH3")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 25_769, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 25_769)
        let optronics = try #require(
            emp.rows.first { $0.labelRaw == "OptronicsReportableSegmentMember" })
        #expect(optronics.amount == 12_798)
        #expect(optronics.label == "オプトロニクス")

        // R&D は注記本文（HTMLテキストブロック）に「全社技術部門10,725百万円」の内訳が
        // あるが XBRL dimension タグが無いため未タグ分が残り、needs_review=true が正しい
        // （2026-08-03 実データ確認。SCREEN HD も同型）。
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 46_771_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
    }

    @Test func hondaEmployeesMatchesDisclosedSegmentTotalsRDStaysNeedsReview() async throws {
        guard await Self.ensureAvailable("S100VYOD") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYOD")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 194_173, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 194_173)
        let automobile = try #require(
            emp.rows.first { $0.labelRaw == "AutomobileBusinessReportableSegmentMember" })
        #expect(automobile.amount == 133_665)
        #expect(automobile.label == "四輪事業")

        // R&D 注記21は費用の性質別（発生支出／資産化／償却）の調整であり事業セグメント別の
        // 内訳ではない。四輪事業のR&D費はこの書類のどこにも（タグにもテキストにも）
        // セグメント単位で開示されていない正当な欠測（2026-08-03 実データ確認）。
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 1_099_482_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
    }

    @Test func nomuraResearchInstituteEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VZKL") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VZKL")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 16_679, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 16_679)
        let industrialIT = try #require(
            emp.rows.first { $0.labelRaw == "IndustrialITSolutionsReportableSegmentMember" })
        #expect(industrialIT.amount == 6_034)
        #expect(industrialIT.label == "産業ＩＴソリューション")

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 6_114_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let financialIT = try #require(
            rd.rows.first { $0.labelRaw == "FinancialITSolutionsReportableSegmentMember" })
        #expect(financialIT.amount == 2_929_000_000)
        #expect(financialIT.label == "金融ＩＴソリューション")
    }

    @Test func toyotaEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VWVY") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VWVY")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 383_853, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 383_853)
        let automotive = try #require(
            emp.rows.first { $0.labelRaw == "AutomotiveReportableSegmentMember" })
        #expect(automotive.amount == 339_062)
        #expect(automotive.label == "自動車")

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 1_326_496_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let automotiveRD = try #require(
            rd.rows.first { $0.labelRaw == "AutomotiveReportableSegmentMember" })
        #expect(automotiveRD.amount == 1_310_754_000_000)
        #expect(automotiveRD.label == "自動車")
    }

    @Test func sumitomoCorpEmployeesMatchesDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VYV6") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VYV6")

        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 83_327, axis: "employees", labelsByTag: labels))
        #expect(snapshot.needsReview == false)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == 83_327)
        let mediaDigital = try #require(
            snapshot.rows.first { $0.labelRaw == "MediaAndDigitalReportableSegmentMember" })
        #expect(mediaDigital.amount == 20_816)
        #expect(mediaDigital.label == "メディア・デジタル")
    }

    @Test func ajinomotoEmployeesAndRDMatchDisclosedSegmentTotals() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let (facts, labels) = Self.employeesFactsAndLabels("S100VXJA")

        let emp = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: 34_860, axis: "employees", labelsByTag: labels))
        #expect(emp.needsReview == false)
        #expect(emp.rows.map(\.amount).reduce(0, +) == 34_860)
        let seasonings = try #require(
            emp.rows.first { $0.labelRaw == "SeasoningsAndFoodsReportableSegmentMember" })
        #expect(seasonings.amount == 22_096)
        #expect(seasonings.label == "調味料・食品")

        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 30_921_000_000, axis: "research_and_development",
                labelsByTag: labels))
        #expect(rd.needsReview == false)
        let healthcare = try #require(
            rd.rows.first { $0.labelRaw == "HealthcareAndOthersReportableSegmentMember" })
        #expect(healthcare.amount == 11_212_000_000)
        #expect(healthcare.label == "ヘルスケア等")
    }

    /// business 軸（`normalizeSalesBasis` 経路）でも同じラベル解決が効くこと。
    /// メンバー名は事業年度で変わりうるため固定文字列にせず、
    /// 「少なくとも1行は生member名と異なる日本語ラベルに解決される」ことだけを検証する。
    @Test func kyoceraBusinessAxisResolvesJapaneseLabels() async throws {
        guard await Self.ensureAvailable("S100TSIJ") else { return }
        let xbrlDir = Self.xbrlDir("S100TSIJ")
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)
        #expect(segments.method == "xbrl_facts")
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)

        let snapshot = try #require(
            BreakdownNormalizer.normalize(
                segments, consolidatedSales: 1_069_763_000_000, labelsByTag: labelsByTag))
        #expect(snapshot.axis == "business")
        #expect(snapshot.rows.contains { $0.label != nil && $0.label != $0.labelRaw })
    }
}

// smoke 固定11社（`SmokeTests.swift`と同じ docID セット）での research_and_development 軸
// 実データゴールデン（2026-08-11）。キャッシュは `tmp_cache/edinet/`（`SmokeCacheSupport.cacheDir`、
// 他の smoke オラクル形式テストと同じ場所）。全社とも実タグ
// `ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities` を確認済みのため denominatorTag
// もあわせて固定する。ニチレイ・富士フイルム・キヤノンの乖離は開示側が「その他」「基礎研究費」を
// 地の文（プレーンテキスト）のみで開示しXBRLタグを振っていないための正当な未タグ残差（元のiXBRLを
// 直接確認して金額まで一致を確認済み。292/9,105/52,971百万円は`ix:nonFraction`化されていない）。
@Suite struct SmokeResearchAndDevelopmentBreakdownTests {

    private static let xbrlRoot = SmokeCacheSupport.cacheDir

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID])
        guard cacheAvailable(docID) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func factsAndLabels(_ docID: String) -> (facts: [BreakdownFact], labels: [String: String]) {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        return (facts, XBRLUtils.loadLabelsByTag(in: dir))
    }

    private static let rdTag = "ResearchAndDevelopmentExpensesResearchAndDevelopmentActivities"

    // MARK: - resolved・needsReview=false

    @Test func ajinomotoResolvesFiveSegmentRows() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let (facts, labels) = Self.factsAndLabels("S100VXJA")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 30_921_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.count == 5)
        let healthcare = try #require(rd.rows.first { $0.labelRaw == "HealthcareAndOthersReportableSegmentMember" })
        #expect(healthcare.amount == 11_212_000_000)
        #expect(healthcare.label == "ヘルスケア等")
        let unallocated = try #require(
            rd.rows.first { $0.labelRaw == "UnallocatedAmountsAndEliminationMember" })
        #expect(unallocated.amount == 9_562_000_000)
        #expect(unallocated.rowKind == "reconciling")
    }

    @Test func okumaTotalOnlyResolvesWithoutSegmentRowsUsingRealTag() async throws {
        guard await Self.ensureAvailable("S100W043") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W043")
        #expect(facts.filter { $0.tag == Self.rdTag }.isEmpty)  // セグメントdimension開示なし
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 4_409_000_000, totalTag: Self.rdTag,
                axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominator == 4_409_000_000)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.isEmpty)
    }

    @Test func kubotaResolvesTwoSegmentRowsSummingExactlyToTotal() async throws {
        guard await Self.ensureAvailable("S100XR0M") else { return }
        let (facts, labels) = Self.factsAndLabels("S100XR0M")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 110_300_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.map(\.amount).reduce(0, +) == 110_300_000_000)
        let machinery = try #require(rd.rows.first { $0.labelRaw == "MachineryReportableSegmentMember" })
        #expect(machinery.amount == 103_500_000_000)
        #expect(machinery.label == "機械")
    }

    @Test func suzukiResolvesFourSegmentRowsSummingExactlyToTotal() async throws {
        guard await Self.ensureAvailable("S100W4MT") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W4MT")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 265_600_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == false)
        #expect(rd.denominatorTag == Self.rdTag)
        #expect(rd.rows.map(\.amount).reduce(0, +) == 265_600_000_000)
        let automobile = try #require(
            rd.rows.first { $0.labelRaw == "AutomobileBusinessReportableSegmentMember" })
        #expect(automobile.amount == 239_100_000_000)
        #expect(automobile.label == "四輪事業")
    }

    // MARK: - resolved・needsReview=true（未タグ残差、実データ確認済み）

    /// 「その他の事業は291百万円となりました」は地の文のみでXBRLタグなし（実データ確認済み）。
    @Test func nichireiRDStaysNeedsReviewForUntaggedOtherSegment() async throws {
        guard await Self.ensureAvailable("S100VYA0") else { return }
        let (facts, labels) = Self.factsAndLabels("S100VYA0")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 2_206_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
        #expect(rd.rows.map(\.amount).reduce(0, +) == 1_915_000_000)
        let processedFoods = try #require(
            rd.rows.first { $0.labelRaw == "ProcessedFoodsReportableSegmentsMember" })
        #expect(processedFoods.amount == 1_436_000_000)
        #expect(processedFoods.label == "加工食品")
    }

    /// 「基礎研究費は9,105百万円です」は地の文のみでXBRLタグなし（実データ確認済み）。
    @Test func fujifilmRDStaysNeedsReviewForUntaggedBasicResearch() async throws {
        guard await Self.ensureAvailable("S100W3XJ") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W3XJ")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 163_399_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
        #expect(rd.rows.map(\.amount).reduce(0, +) == 154_294_000_000)
        let healthcare = try #require(rd.rows.first { $0.labelRaw == "HealthcareReportableSegmentsMember" })
        #expect(healthcare.amount == 60_698_000_000)
        #expect(healthcare.label == "ヘルスケア")
    }

    /// 「基礎研究等のその他及び全社に係る研究開発費は52,971百万円」は地の文のみでXBRLタグなし
    /// （実データ確認済み）。
    @Test func canonRDStaysNeedsReviewForUntaggedBasicResearchAndCorporate() async throws {
        guard await Self.ensureAvailable("S100XTLJ") else { return }
        let (facts, labels) = Self.factsAndLabels("S100XTLJ")
        let rd = try #require(
            BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: 339_288_000_000, axis: "research_and_development", labelsByTag: labels))
        #expect(rd.needsReview == true)
        #expect(rd.warnings.contains("research_and_development_segment_sum_far_from_total"))
        #expect(rd.rows.map(\.amount).reduce(0, +) == 286_317_000_000)
        let imaging = try #require(
            rd.rows.first { $0.labelRaw == "ImagingBusinessUnitReportableSegmentsMember" })
        #expect(imaging.amount == 112_298_000_000)
        #expect(imaging.label == "イメージングビジネスユニット")
    }

    // MARK: - nil（RD非開示、正当欠測）

    @Test func azPlanningHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100VU4O") else { return }
        let (facts, labels) = Self.factsAndLabels("S100VU4O")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
    }

    @Test func tohoRemacHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100XRD8") else { return }
        let (facts, labels) = Self.factsAndLabels("S100XRD8")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
    }

    @Test func mufgBankHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W4FB")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
    }

    @Test func smfgBankHasNoResearchAndDevelopmentDisclosure() async throws {
        guard await Self.ensureAvailable("S100W0S7") else { return }
        let (facts, labels) = Self.factsAndLabels("S100W0S7")
        let rd = BreakdownNormalizer.normalizeResearchAndDevelopment(
            facts: facts, total: nil, axis: "research_and_development", labelsByTag: labels)
        #expect(rd == nil)
    }
}

// smoke 固定11社での employees 軸実データゴールデン（2026-08-12 目視確認済み）。
// キャッシュは `tmp_cache/edinet/`（`SmokeCacheSupport.cacheDir`）。全社 `NumberOfEmployees`
// の事業セグメント dimension 付き fact から内訳を組み立て、denominator は非dimension の
// 全社合計（`smoke/smoke_expected` の employees.current と一致）。11社すべて
// needsReview=false・sum(rows)==denominator・denominatorTag=NumberOfEmployees。
// オークマのみ報告セグメントが地域軸（日本/米州/欧州/アジア・パシフィック）。
@Suite struct SmokeEmployeesBreakdownTests {

    private static let xbrlRoot = SmokeCacheSupport.cacheDir
    private static let employeeTag = "NumberOfEmployees"

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID])
        guard cacheAvailable(docID) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func factsAndLabels(_ docID: String) -> (facts: [BreakdownFact], labels: [String: String]) {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        return (facts, XBRLUtils.loadLabelsByTag(in: dir))
    }

    private static func expectEmployees(
        docID: String, total: Double,
        rows: [(labelRaw: String, label: String?, amount: Double, rowKind: String)]
    ) async throws {
        guard await ensureAvailable(docID) else { return }
        let (facts, labels) = factsAndLabels(docID)
        let snapshot = try #require(
            BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: total, axis: "employees", labelsByTag: labels))
        #expect(snapshot.axis == "employees")
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.denominatorTag == employeeTag)
        #expect(snapshot.denominator == total)
        #expect(snapshot.rows.map(\.amount).reduce(0, +) == total)
        #expect(snapshot.rows.count == rows.count)
        for expected in rows {
            let row = try #require(snapshot.rows.first { $0.labelRaw == expected.labelRaw })
            #expect(row.amount == expected.amount)
            #expect(row.rowKind == expected.rowKind)
            #expect(row.label == expected.label)
        }
    }

    @Test func ajinomotoEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VXJA", total: 34_860,
            rows: [
                ("CorporateSharedMember", nil, 780, "reconciling"),
                ("FrozenFoodsReportableSegmentMember", "冷凍食品", 5_478, "segment"),
                ("HealthcareAndOthersReportableSegmentMember", "ヘルスケア等", 5_321, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    nil, 1_185, "segment"),
                ("SeasoningsAndFoodsReportableSegmentMember", "調味料・食品", 22_096, "segment"),
            ])
    }

    @Test func nichireiEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VYA0", total: 16_626,
            rows: [
                ("CorporateSharedMember", nil, 229, "reconciling"),
                ("LogisticsReportableSegmentsMember", "低温物流", 4_926, "segment"),
                ("MarineProductsReportableSegmentsMember", "水産", 744, "segment"),
                ("MeatAndPoultryProductsReportableSegmentsMember", "畜産", 397, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    nil, 190, "segment"),
                ("ProcessedFoodsReportableSegmentsMember", "加工食品", 10_125, "segment"),
                ("RealEstateReportableSegmentsMember", "不動産", 15, "segment"),
            ])
    }

    @Test func azPlanningEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100VU4O", total: 63,
            rows: [
                ("CorporateSharedMember", nil, 15, "reconciling"),
                ("RealEstateLeasingReportableSegmentMember", "不動産賃貸事業", 4, "segment"),
                ("RealEstateManagementReportableSegmentMember", "不動産管理事業", 5, "segment"),
                ("RealEstateSalesReportableSegmentMember", "不動産販売事業", 39, "segment"),
            ])
    }

    @Test func fujifilmEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W3XJ", total: 72_593,
            rows: [
                ("BusinessInnovationReportableSegmentsMember", "ビジネスイノベーション", 34_173, "segment"),
                ("CorporateSharedMember", nil, 4_129, "reconciling"),
                ("ElectronicsReportableSegmentsMember", "エレクトロニクス", 6_472, "segment"),
                ("HealthcareReportableSegmentsMember", "ヘルスケア", 21_369, "segment"),
                ("ImagingReportableSegmentsMember", "イメージング", 6_450, "segment"),
            ])
    }

    @Test func okumaEmployeesMatchGeographyReportableSegments() async throws {
        try await Self.expectEmployees(
            docID: "S100W043", total: 4_071,
            rows: [
                ("AmericasReportableSegmentsMember", "米州", 264, "segment"),
                ("AsiaAndPacificReportableSegmentsMember", "アジア・パシフィック", 753, "segment"),
                ("EuropeReportableSegmentsMember", "欧州", 388, "segment"),
                ("JapanReportableSegmentsMember", "日本", 2_666, "segment"),
            ])
    }

    @Test func kubotaEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100XR0M", total: 52_503,
            rows: [
                ("CorporateSharedMember", nil, 1_403, "reconciling"),
                ("MachineryReportableSegmentMember", "機械", 41_342, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    nil, 1_379, "segment"),
                ("WaterAndEnvironmentReportableSegmentMember", "水・環境", 8_379, "segment"),
            ])
    }

    @Test func suzukiEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W4MT", total: 74_077,
            rows: [
                ("AutomobileBusinessReportableSegmentMember", "四輪事業", 64_149, "segment"),
                ("CorporateSharedMember", nil, 996, "reconciling"),
                ("MarineBusinessReportableSegmentMember", "マリン事業", 1_460, "segment"),
                ("MotorcycleBusinessReportableSegmentMember", "二輪事業", 7_121, "segment"),
                ("OtherBusinessReportableSegmentMember", "その他事業", 351, "segment"),
            ])
    }

    @Test func tohoRemacEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100XRD8", total: 74,
            rows: [
                ("RealEstateBusinessMember", "不動産事業", 2, "segment"),
                ("ShoesBusinessMember", "シューズ事業", 72, "segment"),
            ])
    }

    @Test func canonEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100XTLJ", total: 165_547,
            rows: [
                ("ImagingBusinessUnitReportableSegmentsMember", "イメージングビジネスユニット", 26_367, "segment"),
                ("IndustryBusinessUnitReportableSegmentsMember", "インダストリアルビジネスユニット", 7_757, "segment"),
                ("MedicalBusinessUnitReportableSegmentsMember", "メディカルビジネスユニット", 13_347, "segment"),
                ("OtherAndCorporateMember", "その他及び全社", 12_138, "segment"),
                ("PrintingBusinessUnitReportableSegmentsMember", "プリンティングビジネスユニット", 105_938, "segment"),
            ])
    }

    @Test func mufgEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W4FB", total: 156_253,
            rows: [
                ("AssetManagementAndInvestorServicesBusinessGroupMember", "受託財産事業本部", 12_635, "segment"),
                ("CommercialBankingAndWealthManagementBusinessGroupMember", "法人・ウェルスマネジメント事業本部", 18_905, "segment"),
                ("GlobalCommercialBankingBusinessGroupMember", "グローバルコマーシャルバンキング事業本部", 71_479, "segment"),
                ("GlobalCorporateAndInvestmentBankingBusinessGroupMember", "グローバルCIB事業本部", 3_313, "segment"),
                ("GlobalMarketsBusinessGroupMember", "市場事業本部", 2_546, "segment"),
                ("JapaneseCorporateAndInvestmentBankingBusinessGroupMember", "コーポレートバンキング事業本部", 6_816, "segment"),
                ("OtherMember", "その他", 23_101, "segment"),
                ("RetailAndDigitalBusinessGroupMember", "リテール・デジタル事業本部", 17_458, "segment"),
            ])
    }

    @Test func smfgEmployeesMatchDisclosedSegmentTotals() async throws {
        try await Self.expectEmployees(
            docID: "S100W0S7", total: 122_978,
            rows: [
                ("GlobalBusinessUnitReportableSegmentMember", "グローバル事業部門", 69_590, "segment"),
                ("GlobalMarketsBusinessUnitReportableSegmentMember", "市場事業部門", 1_371, "segment"),
                ("HeadOfficeAccountReportableSegmentMember", "本社管理", 16_293, "segment"),
                ("RetailBusinessUnitReportableSegmentMember", "リテール事業部門", 26_979, "segment"),
                ("WholesaleBusinessUnitReportableSegmentMember", "ホールセール事業部門", 8_745, "segment"),
            ])
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

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する。
    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
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

    @Test func bridgestoneResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100XRPR") else { return }
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

    @Test func densoResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100Y9T1") else { return }
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

    @Test func sumitomoResolvesViaSegmentInfoLLMFromProductTable() async throws {
        guard await Self.ensureAvailable("S100YH3M") else { return }
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

    @Test func eisaiResolvesViaSegmentInfoLLMFromNeurologyOncologyTable() async throws {
        guard await Self.ensureAvailable("S100YB05") else { return }
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

    // MARK: - 資生堂 S100XSCU（2026-08-14）

    @Test func shiseidoResolvesGeographicBusinessSegmentsViaSegmentInfoLLM() async throws {
        guard await Self.ensureAvailable("S100XSCU") else { return }
        // 報告セグメント名が「日本事業」「米州事業」等の地域事業ユニット。金額はユーザー確認済み
        // （分母 969,992 百万円と一致）。ラベルが地名に見えるため needs_review は立つが、
        // 中身は事業軸として採用する（本番 segment_info_llm / S100XSCU）。
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XSCU"))
        let joined = segments.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("日本事業"))

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "日本事業")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "日本事業", "amount": 295_343, "profit": 38_972, "row_kind": "segment"],
                ["label": "中国・トラベルリテール事業", "amount": 342_244, "profit": 64_525, "row_kind": "segment"],
                ["label": "アジアパシフィック事業", "amount": 73_290, "profit": 5_079, "row_kind": "segment"],
                ["label": "米州事業", "amount": 106_584, "profit": -11_566, "row_kind": "segment"],
                ["label": "欧州事業", "amount": 141_129, "profit": 3_949, "row_kind": "segment"],
                ["label": "その他", "amount": 11_399, "profit": -1_259, "row_kind": "segment"],
                ["label": "合計", "amount": 969_992, "profit": 99_700, "row_kind": "subtotal"],
                ["label": "調整額", "amount": 0, "profit": -55_179, "row_kind": "reconciling"],
                ["label": "連結", "amount": 969_992, "profit": 44_520, "row_kind": "subtotal"],
            ],
            "notes": "報告セグメント表を採用。事業が列見出しのため転置。",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 969_992_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(snapshot?.needsReview == true)
        #expect(snapshot?.warnings.contains("business_label_looks_like_geography") == true)
        #expect(snapshot?.denominator == sales)
        let japan = try #require(snapshot?.rows.first { $0.labelRaw == "日本事業" })
        #expect(japan.amount == 295_343_000_000)
        #expect(japan.profit == 38_972_000_000)
        let china = try #require(snapshot?.rows.first { $0.labelRaw.contains("トラベルリテール") })
        #expect(china.amount == 342_244_000_000)
        #expect(await client.timesCalled() == 1)
    }

    @Test func asahi2023ResolvesJapanOverseasGeographyViaLLM() async throws {
        guard await Self.ensureAvailable("S100QG09") else { return }
        let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: Self.xbrlDir("S100QG09"))
        #expect(geography.method == "html_table")

        let tableIndex = Self.preferredTableIndex(geography.tables, containing: "1,281,768")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当年度",
            "rows": [
                ["label": "日本", "amount": 1_281_768, "row_kind": "segment"],
                ["label": "海外", "amount": 1_229_340, "row_kind": "segment"],
                ["label": "合計", "amount": 2_511_108, "row_kind": "subtotal"],
            ],
            "notes": "対外部売上収益の日本/海外表。うちオーストラリアは内数のため出さない。",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 2_511_108_000_000.0

        let (snapshot, source, _) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: sales, client: client
        )

        #expect(source == .geographyLLM)
        #expect(snapshot?.axis == "geography")
        #expect(snapshot?.needsReview == false)
        #expect(snapshot?.denominator == sales)
        let japan = try #require(snapshot?.rows.first { $0.labelRaw == "日本" })
        #expect(japan.amount == 1_281_768_000_000)
        let overseas = try #require(snapshot?.rows.first { $0.labelRaw == "海外" })
        #expect(overseas.amount == 1_229_340_000_000)
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

// MARK: - goodwill 軸（2026-08-12追加）

/// smoke 固定11社の goodwill 軸床（Step 1）。J-GAAP4社は resolved、残7社は segment dimension
/// タグ欠如で not_found（IFRS/US-GAAP/非連結等。`goodwill_and_intangibles` note_type とは別経路）。
@Suite struct SmokeGoodwillBreakdownTests {

    private static let xbrlRoot = SmokeCacheSupport.cacheDir

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID])
        guard FileManager.default.fileExists(atPath: xbrlDir(docID).path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func factsAndLabels(_ docID: String) -> (facts: [BreakdownFact], labels: [String: String]) {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        return (facts, XBRLUtils.loadLabelsByTag(in: dir))
    }

    private static func resolveGoodwill(docID: String) -> BreakdownSnapshot? {
        let (facts, labels) = factsAndLabels(docID)
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir(docID), nilAsZero: false)
        let totalItem = resolveItem(fieldSetFromInstant(allTagElements), tags: Xbrl.goodwillSegmentTags)
        return BreakdownNormalizer.normalizeGoodwill(
            facts: facts, total: totalItem.current, totalTag: totalItem.tag,
            axis: breakdownAxisGoodwill, labelsByTag: labels)
    }

    private static func expectGoodwillResolved(
        docID: String, total: Double, totalTag: String,
        rows: [(labelRaw: String, amount: Double, rowKind: String)]
    ) async throws {
        guard await ensureAvailable(docID) else { return }
        let snapshot = try #require(resolveGoodwill(docID: docID))
        #expect(snapshot.axis == breakdownAxisGoodwill)
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.denominatorTag == totalTag)
        #expect(snapshot.denominator == total)
        #expect(snapshot.rows.count == rows.count)
        for expected in rows {
            let row = try #require(snapshot.rows.first { $0.labelRaw == expected.labelRaw })
            #expect(row.amount == expected.amount)
            #expect(row.rowKind == expected.rowKind)
        }
    }

    private static func expectGoodwillNotFound(docID: String) async throws {
        guard await ensureAvailable(docID) else { return }
        #expect(resolveGoodwill(docID: docID) == nil)
    }

    @Test func ajinomotoGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100VXJA")
    }

    @Test func nichireiGoodwillSplitsAcrossLogisticsAndProcessedFoods() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100VYA0", total: 7_356_000_000, totalTag: "Goodwill",
            rows: [
                ("LogisticsReportableSegmentsMember", 6_604_000_000, "segment"),
                ("MarineProductsReportableSegmentsMember", 0, "segment"),
                ("MeatAndPoultryProductsReportableSegmentsMember", 0, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    0, "segment"),
                ("ProcessedFoodsReportableSegmentsMember", 751_000_000, "segment"),
                ("RealEstateReportableSegmentsMember", 0, "segment"),
                ("ReportableSegmentsMember", 7_356_000_000, "subtotal"),
                ("TotalOfReportableSegmentsAndOthersMember", 7_356_000_000, "subtotal"),
                ("UnallocatedAmountsAndEliminationMember", 0, "reconciling"),
            ])
    }

    @Test func azPlanningGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100VU4O")
    }

    @Test func fujifilmGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100W3XJ")
    }

    @Test func okumaGoodwillAllInEuropeSegment() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100W043", total: 1_053_000_000, totalTag: "Goodwill",
            rows: [
                ("AmericasReportableSegmentsMember", 0, "segment"),
                ("AsiaAndPacificReportableSegmentsMember", 0, "segment"),
                ("EuropeReportableSegmentsMember", 1_053_000_000, "segment"),
                ("JapanReportableSegmentsMember", 0, "segment"),
                ("UnallocatedAmountsAndEliminationMember", 0, "reconciling"),
            ])
    }

    @Test func kubotaGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100XR0M")
    }

    @Test func suzukiGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100W4MT")
    }

    @Test func tohoRemacGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100XRD8")
    }

    @Test func canonGoodwillNotFound() async throws {
        try await Self.expectGoodwillNotFound(docID: "S100XTLJ")
    }

    @Test func mufgGoodwillMatchesBalanceSheetTotal() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100W4FB", total: 530_386_000_000, totalTag: "Goodwill",
            rows: [
                ("AssetManagementAndInvestorServicesBusinessGroupMember", 369_353_000_000, "segment"),
                ("CommercialBankingAndWealthManagementBusinessGroupMember", 0, "segment"),
                ("GlobalCommercialBankingBusinessGroupMember", 50_834_000_000, "segment"),
                ("GlobalCorporateAndInvestmentBankingBusinessGroupMember", 35_146_000_000, "segment"),
                ("GlobalMarketsBusinessGroupMember", 0, "segment"),
                ("JapaneseCorporateAndInvestmentBankingBusinessGroupMember", 254_000_000, "segment"),
                ("OtherMember", 0, "segment"),
                ("RetailAndDigitalBusinessGroupMember", 74_797_000_000, "segment"),
                ("TotalMember", 530_386_000_000, "subtotal"),
                ("TotalOfCustomerBusinessUnitMember", 530_386_000_000, "subtotal"),
            ])
    }

    @Test func smfgGoodwillMatchesBalanceSheetTotal() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100W0S7", total: 230_070_000_000, totalTag: "Goodwill",
            rows: [
                ("GlobalBusinessUnitReportableSegmentMember", 161_611_000_000, "segment"),
                ("GlobalMarketsBusinessUnitReportableSegmentMember", 0, "segment"),
                ("HeadOfficeAccountsEtcReportableSegmentMember", 47_749_000_000, "reconciling"),
                ("ReportableSegmentsMember", 230_070_000_000, "subtotal"),
                ("RetailBusinessUnitReportableSegmentMember", 20_709_000_000, "segment"),
                ("WholesaleBusinessUnitReportableSegmentMember", 0, "segment"),
            ])
    }
}

/// smoke 床では拾えないエッジケースの golden（Step 2）。`normalizeGoodwill` 決定論検証。
/// IFRS の `goodwill_and_intangibles` note_type は `GoodwillAndIntangiblesOracleFormatTests` が別途カバー。
@Suite struct RealXbrlGoodwillBreakdownTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard FileManager.default.fileExists(atPath: xbrlDir(docID).path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func resolveGoodwill(docID: String) -> BreakdownSnapshot? {
        let dir = xbrlDir(docID)
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: dir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: dir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap)
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: dir)
        let allTagElements = XBRLUtils.collectAllNumericElements(in: dir, nilAsZero: false)
        let totalItem = resolveItem(fieldSetFromInstant(allTagElements), tags: Xbrl.goodwillSegmentTags)
        return BreakdownNormalizer.normalizeGoodwill(
            facts: facts, total: totalItem.current, totalTag: totalItem.tag,
            axis: breakdownAxisGoodwill, labelsByTag: labelsByTag)
    }

    private static func expectGoodwillResolved(
        docID: String, total: Double, totalTag: String,
        rows: [(labelRaw: String, amount: Double, rowKind: String)]
    ) async throws {
        guard await ensureAvailable(docID) else { return }
        let snapshot = try #require(resolveGoodwill(docID: docID))
        #expect(snapshot.axis == breakdownAxisGoodwill)
        #expect(snapshot.needsReview == false)
        #expect(snapshot.warnings.isEmpty)
        #expect(snapshot.denominatorTag == totalTag)
        #expect(snapshot.denominator == total)
        #expect(snapshot.rows.count == rows.count)
        for expected in rows {
            let row = try #require(snapshot.rows.first { $0.labelRaw == expected.labelRaw })
            #expect(row.amount == expected.amount)
            #expect(row.rowKind == expected.rowKind)
        }
    }

    // MARK: - 横河電機 S100VY8X（2026-08-13）
    //
    // のれん全額が単一報告セグメント（制御）に集中。オークマ型（Europe 1セグメント）と同型だが
    // 銀行の GoodwillBeforeOffsetting 分離パターンではない通常 J-GAAP 事業会社。

    @Test func yokogawaGoodwillAllInControlSegment() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100VY8X", total: 6_563_000_000, totalTag: "Goodwill",
            rows: [
                ("IndustrialAutomationAndControlReportableSegmentsMember", 6_563_000_000, "segment"),
                ("NewBussinessesOtherReportableSegmentsMember", 0, "segment"),
                ("TestAndMeasurementReportableSegmentsMember", 0, "segment"),
            ])
    }

    // MARK: - SOMPO S100R1LR（2026-08-13）
    //
    // 保険持株。介護・海外保険の2セグメントにのれんが配分。ReportableSegmentsMember subtotal あり。
    // 生命・損保セグメントはのれんゼロ（dimension 行は出る）。

    @Test func sompoGoodwillSplitsAcrossNursingCareAndOverseasInsurance() async throws {
        try await Self.expectGoodwillResolved(
            docID: "S100R1LR", total: 197_729_000_000, totalTag: "Goodwill",
            rows: [
                ("DomesticLifeInsuranceBusinessReportableSegmentsMember", 0, "segment"),
                ("DomesticPAndCInsuranceBusinessReportableSegmentsMember", 0, "segment"),
                ("NursingCareAndSeniorBusinessReportableSegmentsMember", 78_983_000_000, "segment"),
                (
                    "OperatingSegmentsNotIncludedInReportableSegmentsAndOtherRevenueGeneratingBusinessActivitiesMember",
                    0, "segment"),
                ("OverseasInsuranceBusinessReportableSegmentsMember", 118_746_000_000, "segment"),
                ("ReportableSegmentsMember", 197_729_000_000, "subtotal"),
                ("UnallocatedAmountsAndEliminationMember", 0, "reconciling"),
            ])
    }

    // MARK: - トヨタ S100VWVY（2026-08-13）
    //
    // BS にのれん合計タグが無く segment dimension も無い。not_found が正当（note_type 側も
    // `toyotaHasNoGoodwillNoteIsNotApplicableNotAFailure` と対応）。

    @Test func toyotaGoodwillNotFoundIsLegitimate() async throws {
        guard await Self.ensureAvailable("S100VWVY") else { return }
        #expect(Self.resolveGoodwill(docID: "S100VWVY") == nil)
    }
}
