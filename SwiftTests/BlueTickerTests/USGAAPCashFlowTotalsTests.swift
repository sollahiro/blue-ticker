import Foundation
import Testing

@testable import BlueTickerCore

/// US-GAAP の CF 本表合計（営業／投資）のラベル揺れ（「営業活動に使用された現金（純額）」
/// 「営業活動による キャッシュ・フロー合計」等）と Summary タグフォールバック。
/// 正本は statement 本表行。`CashFlowsFromUsedIn*ActivitiesUSGAAPSummaryOfBusinessResults` は
/// 本表ラベルで取れないときだけ使う最終フォールバック。
@Suite struct USGAAPCashFlowTotalsTests {
    private struct Expected {
        let docID: String
        let cfo: Double
        let cfi: Double
    }

    /// 本表ラベルが「…キャッシュ・フロー」以外の会社（修正前は cfo/cfi/cfc が null）。
    private static let labelVariantDocs: [Expected] = [
        // 野村 8604「営業活動に使用された現金（純額）」「投資活動に使用された現金（純額）」
        Expected(docID: "S100YC5C", cfo: -842_960_000_000, cfi: -1_498_923_000_000),
        // 小松 6301「営業活動による現金及び現金同等物の増加（純額）」「…の減少（純額）」
        Expected(docID: "S100YD25", cfo: 448_963_000_000, cfi: -199_232_000_000),
        // オリックス 8591「営業活動から得た現金（純額）」「投資活動に使用した現金（純額）」
        Expected(docID: "S100YG5L", cfo: 1_369_567_000_000, cfi: -1_114_671_000_000),
        // 村田 6981（US-GAAP 期）「営業活動による␣キャッシュ・フロー合計」（セル内改行）
        Expected(docID: "S100R773", cfo: 276_278_000_000, cfi: -157_850_000_000),
        // 野村 8604（2025 年 3 月期）「営業活動から得た（△営業活動に使用された）現金（純額）」
        Expected(docID: "S100VXTD", cfo: -678_611_000_000, cfi: -848_647_000_000),
        // ソニー 6758（米国基準の 2021 年 3 月期）「営業活動から得た現金・預金及び現金同等物（純額）」
        Expected(docID: "S100LM4N", cfo: 1_350_150_000_000, cfi: -1_781_516_000_000),
    ]

    /// 修正前から本番で値が出ている会社。値が変わらないこと（本番 /financials と一致）。
    private static let unchangedDocs: [Expected] = [
        Expected(docID: "S100YIBH", cfo: 410_555_000_000, cfi: -554_604_000_000),  // 4901
        Expected(docID: "S100YG81", cfo: 60_919_000_000, cfi: -70_071_000_000),  // 6645
        Expected(docID: "S100XTLJ", cfo: 475_903_000_000, cfi: -237_450_000_000),  // 7751
    ]

    private func ensureCached(_ docID: String) async -> URL? {
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        await SmokeCacheSupport.ensureCached([docID])
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return nil
        }
        return xbrlDir
    }

    private func cashFlow(_ xbrlDir: URL, docID: String) -> [StatementLineItem]? {
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir, docID: docID, statementTypes: [.cashFlow]
        ) else { return nil }
        return year.cashFlow
    }

    private func summaryCashFlow(_ xbrlDir: URL) -> (cfo: Double?, cfi: Double?) {
        let elements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let fs = fieldSetFromDuration(elements.filter {
            $0.key == StatementFinancialsResolver.usgaapSummaryOperatingCashFlowTag
                || $0.key == StatementFinancialsResolver.usgaapSummaryInvestingCashFlowTag
        })
        return (
            StatementFinancialsResolver.usgaapSummaryCashFlow(
                fs, tag: StatementFinancialsResolver.usgaapSummaryOperatingCashFlowTag),
            StatementFinancialsResolver.usgaapSummaryCashFlow(
                fs, tag: StatementFinancialsResolver.usgaapSummaryInvestingCashFlowTag)
        )
    }

    /// ラベル揺れ 4 社: 本表行のラベル照合だけで取れる（Summary フォールバックに頼らない）。
    @Test(arguments: labelVariantDocs.map(\.docID))
    func labelVariantResolvesFromStatementRows(docID: String) async throws {
        let expected = try #require(Self.labelVariantDocs.first { $0.docID == docID })
        guard let xbrlDir = await ensureCached(docID) else { return }
        let rows = try #require(cashFlow(xbrlDir, docID: docID))
        #expect(
            StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .operating)
                == expected.cfo)
        #expect(
            StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .investing)
                == expected.cfi)

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.cfo == expected.cfo)
        #expect(values.cfi == expected.cfi)
    }

    /// 既に取れている 3 社は値が変わらない。
    @Test(arguments: unchangedDocs.map(\.docID))
    func previouslyResolvedDocsAreUnchanged(docID: String) async throws {
        let expected = try #require(Self.unchangedDocs.first { $0.docID == docID })
        guard let xbrlDir = await ensureCached(docID) else { return }
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.cfo == expected.cfo)
        #expect(values.cfi == expected.cfi)
    }

    /// Summary タグと本表合計の両方があるときは一致する（フォールバックが値を変えない根拠）。
    /// 6645 / 7751 は修正前から本表ラベルで取れていた会社、残りはラベル揺れの会社。
    @Test(arguments: (unchangedDocs + labelVariantDocs).map(\.docID))
    func summaryTagEqualsStatementTotalWhereBothExist(docID: String) async throws {
        guard let xbrlDir = await ensureCached(docID) else { return }
        let rows = try #require(cashFlow(xbrlDir, docID: docID))
        let summary = summaryCashFlow(xbrlDir)
        let statementCFO =
            StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .operating)
        let statementCFI =
            StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .investing)
        if let s = summary.cfo, let t = statementCFO { #expect(s == t) }
        if let s = summary.cfi, let t = statementCFI { #expect(s == t) }
        if docID == "S100YG81" || docID == "S100XTLJ" {
            #expect(summary.cfo != nil && statementCFO != nil)
            #expect(summary.cfi != nil && statementCFI != nil)
        }
    }

    // MARK: - 純関数

    private func row(_ label: String, _ value: Double, _ section: StatementLineSection?)
        -> StatementLineItem
    {
        StatementLineItem(
            tag: "USGAAP_HTML_CF_0", label: label, value: value, unit: "JPY", order: 0,
            section: section)
    }

    @Test func activityTotalIgnoresWhitespaceAndRomanPrefix() {
        let rows = [
            row("Ⅰ　営業活動による\nキャッシュ・フロー合計", 10, .operating),
            row("投資活動に使用された現金 （純額）", -7, .investing),
        ]
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .operating) == 10)
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .investing) == -7)
    }

    @Test func activityTotalSkipsZeroHeaderAndAdjustmentRows() {
        let rows = [
            row("営業活動によるキャッシュ・フロー", 0, .operating),  // 「－」見出し
            row("当期純利益から営業活動による現金及び現金同等物の増加（純額）への調整", 5, .operating),
            row("営業活動による現金及び現金同等物の増加（純額）", 42, .operating),
        ]
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .operating) == 42)
    }

    @Test func activityTotalMatchesRepeatedActivityAndCashDepositVariants() {
        let rows = [
            row("営業活動から得た（△営業活動に使用された）現金（純額）", -9, .operating),
            row("投資活動に使用した 現金・預金及び現金同等物（純額）", -4, .investing),
        ]
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .operating) == -9)
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .investing) == -4)
        // 他区分の名前を括弧内に持つ行は拾わない。
        let crossed = [row("営業活動から得た（△投資活動に使用された）現金（純額）", 1, .operating)]
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(crossed, activity: .operating) == nil)
    }

    @Test func activityTotalRespectsSection() {
        let rows = [row("投資活動によるキャッシュ・フロー", 3, .financing)]
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .investing) == nil)
    }

    @Test func activityTotalReturnsTrueZeroWhenOnlyZeroMatches() {
        let rows = [row("投資活動によるキャッシュ・フロー", 0, .investing)]
        #expect(StatementFinancialsResolver.usgaapCashFlowActivityTotal(rows, activity: .investing) == 0)
    }
}
