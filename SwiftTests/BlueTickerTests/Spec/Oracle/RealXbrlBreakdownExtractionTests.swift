// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳回帰（SPEC_ORACLE の L1 実行器）。
// 対象企業は各 @Test にハードコード。共有モックは RealXbrlBreakdownSupport.swift。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

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
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private func containsAmount(_ markdown: String, _ commaSeparated: String) -> Bool {
        markdown.contains(commaSeparated)
            || markdown.contains(commaSeparated.replacingOccurrences(of: ",", with: ""))
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

    @Test func mitsubishiMergesHorizontallySplitRevenue2BusinessGroupsForFY2026() async throws {
        guard await Self.ensureAvailable("S100YB25") else { return }
        // 事業グループが列の収益表が改ページで左右に割れる。左（地球環境…食品）と
        // 右（S.L.C. / 電力 / 合計 / 連結金額）を1表に結合し、LLM に半分だけ選ばせない。
        // 当期は 2025-04-01〜2026-03-31。合計行の連結金額が連結売上 18,915,995 百万円。
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB25"))
        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let merged = result.tables.filter {
            $0.markdown.contains("地球環境エネルギー") && $0.markdown.contains("S.L.C.")
        }
        #expect(merged.count == 2)
        #expect(merged.map(\.period) == ["前期", "当期"])
        let prior = merged[0].markdown
        let current = merged[1].markdown
        #expect(containsAmount(prior, "18,617,601"))
        #expect(containsAmount(current, "18,915,995"))
        #expect(current.contains("顧客との契約から認識した収益"))
        #expect(current.contains("マテリアルソリューション"))
        #expect(current.contains("金属資源"))
        #expect(current.contains("社会インフラ"))
        #expect(current.contains("モビリティ"))
        #expect(current.contains("食品産業"))
        #expect(current.contains("電力ソリューション"))
        // 合計行（顧客契約＋その他の源泉）。分母と一致する連結金額の内訳。
        #expect(containsAmount(current, "3,267,295"))
        #expect(containsAmount(current, "3,631,197"))
        #expect(containsAmount(current, "4,083,329"))
        #expect(containsAmount(current, "930,638"))
        #expect(containsAmount(current, "837,375"))
        #expect(containsAmount(current, "2,324,535"))
        #expect(containsAmount(current, "2,514,143"))
        #expect(containsAmount(current, "1,318,984"))
        #expect(containsAmount(current, "8,539"))
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

    // MARK: - ディスコ S100YC6I / 東京エレクトロン S100YEOO（2026-08-14）

    @Test func discoExtractsProductRevenueTableFromRevenueRecognition() async throws {
        guard await Self.ensureAvailable("S100YC6I") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YC6I"))
        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("精密加工装置"))
        #expect(joined.contains("精密加工ツール"))
        #expect(joined.contains("273,957") || joined.contains("273957"))
        #expect(joined.contains("94,976") || joined.contains("94976"))
        #expect(joined.contains("67,955") || joined.contains("67955"))
        #expect(joined.contains("436,889") || joined.contains("436889"))
    }

    @Test func tokyoElectronExtractsProductRevenueTableFromRevenueRecognition() async throws {
        guard await Self.ensureAvailable("S100YEOO") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YEOO"))
        #expect(result.method == "html_table")
        #expect(result.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)
        let joined = result.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("新規装置"))
        #expect(joined.contains("フィールドソリューション"))
        #expect(joined.contains("1,817,250") || joined.contains("1817250"))
        #expect(joined.contains("626,282") || joined.contains("626282"))
        #expect(joined.contains("2,443,533") || joined.contains("2443533"))
    }

    // MARK: - 第一生命 S100VZZW（2026-08-14）

    @Test func daiichiLifeKeepsConsolidatedExternalRevenueEntityTotal() async throws {
        guard await Self.ensureAvailable("S100VZZW") else { return }
        let result = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100VZZW"))
        #expect(result.method == "xbrl_facts")
        let snap = try #require(BreakdownNormalizer.normalize(result, consolidatedSales: nil))
        #expect(snap.axis == "business")
        #expect(snap.sourceKind == "xbrl_facts")
        #expect(snap.rows.contains {
            $0.labelRaw.contains("DomesticInsurance") && $0.amount == 7_708_824_000_000
        })
        #expect(snap.rows.contains {
            $0.labelRaw.contains("OverseasInsurance") && $0.amount == 3_621_288_000_000
        })
        #expect(snap.rows.contains {
            $0.labelRaw == "OtherReportableSegmentsMember" && $0.amount == 43_217_000_000
        })
        #expect(snap.rows.contains {
            $0.labelRaw == "ReportableSegmentsMember" && $0.amount == 11_373_330_000_000
        })
        let entity = try #require(snap.rows.first { $0.labelRaw == Xbrl.entityTotalMemberName })
        #expect(entity.amount == 9_873_251_000_000)
        #expect(entity.rowKind == "subtotal")
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

