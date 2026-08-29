// 年次インデックスを事前にシードし、API キーなしでネットワークを遮断して検証する。
// findMostRecentFiling もシードした年次インデックス経由で動く。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite final class EdinetDiscoveryTests {
    private let tmpDir: URL
    private let store: EdinetCacheStore
    private let client: EdinetAPIClient

    private let support = ServiceTestSupport.self

    init() throws {
        tmpDir = try ServiceTestSupport.makeTempDir()
        store = EdinetCacheStore(cacheDir: tmpDir)
        client = EdinetAPIClient(apiKey: nil, cacheStore: store)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - ヘルパー

    private func seedIndex(_ year: Int, _ docs: [[String: Any]]) {
        store.saveDocumentIndex(year, documents: docs, builtThrough: "\(year)-12-31")
    }

    /// 指定年範囲の年次インデックスをシードする（未指定年は空）
    private func seedIndexes(_ years: ClosedRange<Int>, _ docsByYear: [Int: [[String: Any]]]) {
        for year in years {
            seedIndex(year, docsByYear[year] ?? [])
        }
    }

    private func makeAnnualDoc(
        docID: String, edinetCode: String, periodStart: String?, periodEnd: String, submit: String,
        ordinanceCode: String = Api.ordinanceCompanyDisclosure
    ) -> [String: Any] {
        var doc: [String: Any] = [
            "docID": docID,
            "edinetCode": edinetCode,
            "secCode": "98430",
            "docTypeCode": "120",
            "ordinanceCode": ordinanceCode,
            "formCode": ordinanceCode == Api.ordinanceCompanyDisclosure ? "030000" : "09A000",
            "periodEnd": periodEnd,
            "submitDateTime": submit,
        ]
        if let ps = periodStart { doc["periodStart"] = ps }
        return doc
    }

    private func makeAmendmentDoc(
        docID: String, edinetCode: String, parentID: String, submit: String
    ) -> [String: Any] {
        [
            "docID": docID,
            "edinetCode": edinetCode,
            "docTypeCode": "130",
            "ordinanceCode": Api.ordinanceCompanyDisclosure,
            "formCode": "030001",
            "parentDocID": parentID,
            "submitDateTime": submit,
        ]
    }

    private func annualDocs(_ docs: [[String: Any]]) -> [[String: Any]] {
        docs.filter { $0["docTypeCode"] as? String == "120" }
    }

    private func amendmentDocs(_ docs: [[String: Any]]) -> [[String: Any]] {
        docs.filter { $0["_is_amendment"] as? Bool == true }
    }

    // MARK: - buildDocumentIndexForCode

    @Test func testBuildDocumentIndexFindsDocsAcrossFiscalYearChange() async throws {
        // 決算期変更（3月末→12月末）があっても edinetCode ベースで全履歴を取得できること
        let edinetCode = "E12345"
        let year = support.currentUTCYear()
        let todayStr = support.iso(support.utcToday())

        // 最新: 12月末（9ヶ月移行期間）、本日提出 → 直近スキャンで発見できる
        let recent = makeAnnualDoc(
            docID: "S100NEW1", edinetCode: edinetCode,
            periodStart: "\(year - 1)-04-01", periodEnd: "\(year - 1)-12-31",
            submit: "\(todayStr) 10:00"
        )
        let old1 = makeAnnualDoc(
            docID: "S100OLD1", edinetCode: edinetCode,
            periodStart: "\(year - 3)-04-01", periodEnd: "\(year - 2)-03-31",
            submit: "\(year - 2)-06-25 10:00"
        )
        let old2 = makeAnnualDoc(
            docID: "S100OLD2", edinetCode: edinetCode,
            periodStart: "\(year - 4)-04-01", periodEnd: "\(year - 3)-03-31",
            submit: "\(year - 3)-06-24 10:00"
        )
        let amendment = makeAmendmentDoc(
            docID: "S100AMEND", edinetCode: edinetCode, parentID: "S100NEW1",
            submit: "\(todayStr) 11:00"
        )
        // 別会社（同じ secCode・別 edinetCode）: フィルタされるべき
        let other = makeAnnualDoc(
            docID: "S100OTHER", edinetCode: "E99999",
            periodStart: "\(year - 1)-04-01", periodEnd: "\(year - 1)-12-31",
            submit: "\(support.iso(support.addDays(support.utcToday(), -10))) 10:00"
        )

        seedIndexes((year - 3)...year, [
            year - 3: [old2],
            year - 2: [old1],
            year: [recent, amendment, other],
        ])

        let docs = await EdinetDiscovery.buildDocumentIndexForCode(
            code: "9843", client: client, analysisYears: 3
        )

        let annual = annualDocs(docs)
        let amendments = amendmentDocs(docs)

        // 旧3月末2件 + 新12月末1件 = 計3件取得できる
        #expect(annual.count == 3)
        let fyEnds = Set(annual.compactMap { $0["edinet_fy_end"] as? String })
        #expect(fyEnds.contains("\(year - 1)-12-31"))  // 変更後（9ヶ月）
        #expect(fyEnds.contains("\(year - 2)-03-31"))  // 変更前
        #expect(fyEnds.contains("\(year - 3)-03-31"))  // 変更前

        // 別会社はフィルタされる
        #expect(annual.allSatisfy { $0["edinetCode"] as? String == edinetCode })

        // 訂正書類が正しくリンクされる
        #expect(amendments.count == 1)
        #expect(amendments.first?["docID"] as? String == "S100AMEND")
        #expect(amendments.first?["edinet_fy_end"] as? String == "\(year - 1)-12-31")
    }

    @Test func testBuildDocumentIndexReturnsEmptyWhenNoRecentDoc() async throws {
        let year = support.currentUTCYear()
        seedIndexes((year - 1)...year, [:])

        let docs = await EdinetDiscovery.buildDocumentIndexForCode(code: "9999", client: client)

        #expect(docs.isEmpty)
    }

    @Test func testBuildDocumentIndexReturnsEmptyWhenEdinetCodeMissing() async throws {
        let year = support.currentUTCYear()
        let todayStr = support.iso(support.utcToday())
        // edinetCode を持たない書類しか見つからない場合は空を返す
        let doc: [String: Any] = [
            "docID": "S100X",
            "secCode": "99990",
            "docTypeCode": "120",
            "periodEnd": "\(year - 1)-03-31",
            "submitDateTime": "\(todayStr) 10:00",
        ]
        seedIndexes((year - 1)...year, [year: [doc]])

        let docs = await EdinetDiscovery.buildDocumentIndexForCode(code: "9999", client: client)

        #expect(docs.isEmpty)
    }

    @Test func testBuildDocumentIndexAcceptsHalfYearAsSeed() async throws {
        // 半期報告書（160）が seed になっても edinetCode を取得して年次探索できること
        let edinetCode = "E12345"
        let year = support.currentUTCYear()
        let todayStr = support.iso(support.utcToday())
        let halfYearSeed: [String: Any] = [
            "docID": "S100HALF",
            "edinetCode": edinetCode,
            "secCode": "98430",
            "docTypeCode": "160",  // 半期報告書
            "ordinanceCode": Api.ordinanceCompanyDisclosure,
            "periodEnd": "\(year - 1)-09-30",
            "submitDateTime": "\(todayStr) 10:00",
        ]
        let annualDoc = makeAnnualDoc(
            docID: "S100ANN1", edinetCode: edinetCode,
            periodStart: "\(year - 2)-04-01", periodEnd: "\(year - 1)-03-31",
            submit: "\(year - 1)-06-25 10:00"
        )
        seedIndexes((year - 1)...year, [
            year - 1: [annualDoc],
            year: [halfYearSeed],
        ])

        let docs = await EdinetDiscovery.buildDocumentIndexForCode(
            code: "9843", client: client, analysisYears: 1
        )

        let annual = annualDocs(docs)
        #expect(annual.count == 1)
        #expect(annual.first?["edinet_fy_end"] as? String == "\(year - 1)-03-31")
    }

    @Test func testBuildDocumentIndexUsesCalculateFiscalYearWhenPeriodStartMissing() async throws {
        // periodStart がない書類は calculateFiscalYear(periodEnd) で fiscal_year を決める
        let year = support.currentUTCYear()
        let todayStr = support.iso(support.utcToday())

        // 12月期: periodEnd 12/31 → fiscal_year = periodEnd の年（12月期は -1 しない）
        let docDec = makeAnnualDoc(
            docID: "S100NS", edinetCode: "E12345",
            periodStart: nil, periodEnd: "\(year - 1)-12-31",
            submit: "\(todayStr) 10:00"
        )
        seedIndexes((year - 1)...year, [year: [docDec]])

        let docsDec = await EdinetDiscovery.buildDocumentIndexForCode(
            code: "9843", client: client, analysisYears: 1
        )
        let annualDec = annualDocs(docsDec)
        #expect(annualDec.count == 1)
        #expect(annualDec.first?["fiscal_year"] as? Int == year - 1)

        // 3月期: periodEnd 03/31 → fiscal_year = periodEnd の年 - 1
        let docMar = makeAnnualDoc(
            docID: "S100MAR", edinetCode: "E12345",
            periodStart: nil, periodEnd: "\(year)-03-31",
            submit: "\(todayStr) 10:00"
        )
        seedIndexes(year...year, [year: [docMar]])

        let docsMar = await EdinetDiscovery.buildDocumentIndexForCode(
            code: "9843", client: client, analysisYears: 1
        )
        let annualMar = annualDocs(docsMar)
        #expect(annualMar.count == 1)
        #expect(annualMar.first?["fiscal_year"] as? Int == year - 1)
    }

    @Test func testBuildDocumentIndexSlicesToAnalysisYears() async throws {
        // 年次インデックスに analysisYears を超える有報があっても上位 N 件に絞られる
        let edinetCode = "E12345"
        let year = support.currentUTCYear()
        let todayStr = support.iso(support.utcToday())

        // スキャン対象年（year-3 〜 year）に1件ずつ配置。最新は本日提出
        var docsByYear: [Int: [[String: Any]]] = [:]
        for submitYear in (year - 3)...year {
            let periodEndYear = submitYear - 1
            let submit = submitYear == year ? "\(todayStr) 10:00" : "\(submitYear)-03-01 10:00"
            docsByYear[submitYear] = [makeAnnualDoc(
                docID: "S100Y\(submitYear)", edinetCode: edinetCode,
                periodStart: "\(periodEndYear)-01-01", periodEnd: "\(periodEndYear)-12-31",
                submit: submit
            )]
        }
        seedIndexes((year - 3)...year, docsByYear)

        let docs = await EdinetDiscovery.buildDocumentIndexForCode(
            code: "9843", client: client, analysisYears: 3
        )

        let annual = annualDocs(docs)
        #expect(annual.count == 3)
        // 最新3件（periodEnd 降順）
        #expect(annual[0]["edinet_fy_end"] as? String == "\(year - 1)-12-31")
        #expect(annual[1]["edinet_fy_end"] as? String == "\(year - 2)-12-31")
        #expect(annual[2]["edinet_fy_end"] as? String == "\(year - 3)-12-31")
    }

    @Test func testBuildDocumentIndexExcludesTrustBeneficiaryOrdinance030() async throws {
        // docType 120 でも特定有価証券府令(030)の信託受益証券等は会社有報の latest にしない
        let edinetCode = "E03041"
        let year = support.currentUTCYear()
        let todayStr = support.iso(support.utcToday())
        let companySubmit = support.iso(support.addDays(support.utcToday(), -10))

        let company = makeAnnualDoc(
            docID: "S100YCDE", edinetCode: edinetCode,
            periodStart: "\(year - 1)-04-01", periodEnd: "\(year)-03-31",
            submit: "\(companySubmit) 11:38"
        )
        let trust = makeAnnualDoc(
            docID: "S100YZ8K", edinetCode: edinetCode,
            periodStart: "\(year - 1)-06-13", periodEnd: "\(year)-05-31",
            submit: "\(todayStr) 16:00",
            ordinanceCode: "030"
        )
        seedIndexes(year...year, [year: [trust, company]])

        let docs = await EdinetDiscovery.buildDocumentIndexForCode(
            code: "9843", client: client, analysisYears: 3
        )
        let annual = annualDocs(docs)
        #expect(annual.count == 1)
        #expect(annual.first?["docID"] as? String == "S100YCDE")
        #expect(annual.allSatisfy { ($0["ordinanceCode"] as? String) == Api.ordinanceCompanyDisclosure })
    }

    // MARK: - 半期報告書探索（findHalfReportForFy 相当）

    @Test func testFindHalfReportAccepts160WithFyPeriodEnd() async throws {
        // 半期報告書（160）: periodEnd は通期期末・periodStart は期首
        let halfDoc: [String: Any] = [
            "docID": "S100UOCS",
            "secCode": "28020",
            "docTypeCode": "160",
            "docDescription": "半期報告書－第147期(2024/04/01－2025/03/31)",
            "periodStart": "2024-04-01",
            "periodEnd": "2025-03-31",
            "submitDateTime": "2024-11-12 13:08",
            "_edinet_list_date": "2024-11-12",
        ]
        // 検索窓 2024-10-01〜2024-12-29 → 2024 年インデックス
        // 予測翌年度（2026-03-31 期）の検索窓 → 2025 年インデックス（空）
        seedIndexes(2024...2025, [2024: [halfDoc]])

        let prebuiltAnnual: [[String: Any]] = [[
            "docID": "S100ANNUAL",
            "docTypeCode": "120",
            "edinet_fy_end": "2025-03-31",
            "periodStart": "2024-04-01",
            "periodEnd": "2025-03-31",
        ]]

        let docs = await EdinetDiscovery.buildHalfYearDocumentIndexForCode(
            code: "28020", client: client, prebuiltAnnualDocs: prebuiltAnnual
        )

        let doc = docs.first { $0["docID"] as? String == "S100UOCS" }
        #expect(doc != nil)
        #expect(doc?["edinet_fy_end"] as? String == "2025-03-31")
        #expect(doc?["edinet_period_start"] as? String == "2024-04-01")
        #expect(doc?["edinet_period_end"] as? String == "2024-09-30")
        #expect(doc?["period_type"] as? String == "2Q")
        #expect(doc?["fiscal_year"] as? Int == 2024)
    }

    @Test func testFindHalfReportAccepts160WithHalfPeriodEnd() async throws {
        // 半期報告書（160）: 一部企業では periodEnd が半期自体の期末になっている
        // （issue #73: 332A・438A 等、通期期末を報告しない少数派の規約）
        let halfDoc: [String: Any] = [
            "docID": "S100X3OS",
            "secCode": "332A0",
            "docTypeCode": "160",
            "docDescription": "半期報告書－第8期(2025/04/01－2025/09/30)",
            "periodStart": "2025-04-01",
            "periodEnd": "2025-09-30",
            "submitDateTime": "2025-11-13 15:31",
            "_edinet_list_date": "2025-11-13",
        ]
        seedIndexes(2025...2026, [2025: [halfDoc]])

        let prebuiltAnnual: [[String: Any]] = [[
            "docID": "S100W8RB",
            "docTypeCode": "120",
            "edinet_fy_end": "2026-03-31",
            "periodStart": "2025-04-01",
            "periodEnd": "2026-03-31",
        ]]

        let docs = await EdinetDiscovery.buildHalfYearDocumentIndexForCode(
            code: "332A", client: client, prebuiltAnnualDocs: prebuiltAnnual
        )

        let doc = docs.first { $0["docID"] as? String == "S100X3OS" }
        #expect(doc != nil)
        #expect(doc?["edinet_fy_end"] as? String == "2026-03-31")
        #expect(doc?["edinet_period_start"] as? String == "2025-04-01")
        #expect(doc?["edinet_period_end"] as? String == "2025-09-30")
        #expect(doc?["period_type"] as? String == "2Q")
    }

    @Test func testFindHalfReportAcceptsLegacy140WithQ2PeriodEnd() async throws {
        // 旧2Q四半期報告書（140）: periodEnd は2Q末・説明文に「第2四半期」を含む
        let quarterDoc: [String: Any] = [
            "docID": "S100S3PK",
            "secCode": "28020",
            "docTypeCode": "140",
            "docDescription": "四半期報告書－第146期第2四半期(2023/07/01－2023/09/30)",
            "periodStart": "2023-07-01",
            "periodEnd": "2023-09-30",
            "submitDateTime": "2023-11-09 14:57",
            "_edinet_list_date": "2023-11-09",
        ]
        // 検索窓 2023-10-01〜2023-12-29 → 2023 年インデックス
        // 予測翌年度（2025-03-31 期）の検索窓 → 2024 年インデックス（空）
        seedIndexes(2023...2024, [2023: [quarterDoc]])

        let prebuiltAnnual: [[String: Any]] = [[
            "docID": "S100ANNUAL",
            "docTypeCode": "120",
            "edinet_fy_end": "2024-03-31",
            "periodStart": "2023-04-01",
            "periodEnd": "2024-03-31",
        ]]

        let docs = await EdinetDiscovery.buildHalfYearDocumentIndexForCode(
            code: "28020", client: client, prebuiltAnnualDocs: prebuiltAnnual
        )

        let doc = docs.first { $0["docID"] as? String == "S100S3PK" }
        #expect(doc != nil)
        #expect(doc?["edinet_fy_end"] as? String == "2024-03-31")
        #expect(doc?["edinet_period_start"] as? String == "2023-04-01")
        #expect(doc?["edinet_period_end"] as? String == "2023-09-30")
        #expect(doc?["period_type"] as? String == "2Q")
    }
}
