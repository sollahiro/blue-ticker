import Foundation
import Testing

@testable import BlueTickerCore

/// Summary 組立が statement 本表の当期 PL を投影することの実データ回帰。
/// 再 ingest だけでは直らない extractor 欠落（親会社 NP タグ / 非連結 PL 投影）を固定する。
@Suite struct StatementFinancialsProjectionTests {
    private func ensureCached(_ docID: String) async -> URL? {
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        await SmokeCacheSupport.ensureCached([docID])
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return nil
        }
        return xbrlDir
    }

    /// コカ・コーラBJH 2579 / S100XR1L。本表は `ProfitAttributableToOwnersOfParentIFRS`
    /// （親会社帰属 −50,763）。`ProfitLossIFRS`（グループ −50,668 = NCI 95 差）へ落ちない。
    @Test func cocaColaS100XR1LSummaryNetProfitIsParentAttributable() async throws {
        let docID = "S100XR1L"
        guard let xbrlDir = await ensureCached(docID) else { return }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: docID,
            statementTypes: [.incomeStatement]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitAttributableToOwnersOfParentIFRS" && $0.value == -50_763_000_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitLossIFRS" && $0.value == -50_668_000_000
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 893_805_000_000)
        #expect(values.operatingProfit == -72_385_000_000)
        #expect(values.netProfit == -50_763_000_000)
        #expect(values.netProfit != -50_668_000_000)
    }

    /// ニッカトー 5367 / S100Y9NY。非連結のみで PL/BS は `*_NonConsolidatedMember`。
    /// statement は 11,340.9 / 1,071.2 / 775.7 百万円。CF だけ埋まって PL が null にならない。
    @Test func nikkatoS100Y9NYProjectsLatestYearPnLFromStatement() async throws {
        let docID = "S100Y9NY"
        guard let xbrlDir = await ensureCached(docID) else { return }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: docID,
            statementTypes: [.incomeStatement, .cashFlow]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "NetSales" && $0.value == 11_340_906_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "OperatingIncome" && $0.value == 1_071_164_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "ProfitLoss" && $0.value == 775_702_000
            })
        #expect(
            year.cashFlow.contains {
                $0.tag == "NetCashProvidedByUsedInOperatingActivities"
                    && $0.value == 1_675_324_000
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 11_340_906_000)
        #expect(values.operatingProfit == 1_071_164_000)
        #expect(values.netProfit == 775_702_000)
        #expect(values.cfo == 1_675_324_000)
        #expect(values.totalAssets == 18_853_231_000)
    }

    /// statement の `xsi:nil` 合成 0 を高優先売上タグへ載せると、後位の実額を潰す。
    /// overlay は 0 を書かず、IBD の借入金 0 投影とは別ルール。
    @Test func overlaySkipsNilAsZeroSoLaterSalesTagWins() {
        var fs: FieldSet = [
            "NetSales": FieldValue(current: 11_340_906_000, prior: nil)
        ]
        StatementFinancialsResolver.overlayStatementLineCurrents(
            &fs,
            lines: [
                StatementLineItem(
                    tag: "NetSalesIFRS", label: nil, value: 0, unit: "JPY", order: 1),
                StatementLineItem(
                    tag: "NetSales", label: nil, value: 11_340_906_000, unit: "JPY", order: 2),
            ])
        #expect(fs["NetSalesIFRS"] == nil)
        #expect(fs["NetSales"]?.current == 11_340_906_000)
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 11_340_906_000)
    }

    @Test func overlayProjectsNonZeroStatementCurrentOntoEmptyFieldSet() {
        var fs: FieldSet = [:]
        StatementFinancialsResolver.overlayStatementLineCurrents(
            &fs,
            lines: [
                StatementLineItem(
                    tag: "NetSales", label: nil, value: 11_340_906_000, unit: "JPY", order: 1),
                StatementLineItem(
                    tag: "OperatingIncome", label: nil, value: 1_071_164_000, unit: "JPY",
                    order: 2),
                StatementLineItem(
                    tag: "ProfitLoss", label: nil, value: 775_702_000, unit: "JPY", order: 3),
            ])
        let result = IncomeStatementExtractor.extract(fieldSet: fs, accountingStandard: "J-GAAP")
        #expect(result.sales == 11_340_906_000)
        #expect(result.operatingProfit == 1_071_164_000)
        #expect(result.netProfit == 775_702_000)
    }

    /// 9436 沖縄セルラー / S100Y9T5。本表は電気通信事業 52,291 と附帯事業 34,057 に分かれ、
    /// 連結営業収益合計は `OperatingRevenue1SummaryOfBusinessResults` = 86,348。
    /// 合計タグがあればそれを使う。内訳タグを売上にしない。
    @Test func okinawaCellularS100Y9T5SummarySalesIsConsolidatedOperatingRevenueTotal() async throws {
        let docID = "S100Y9T5"
        guard let xbrlDir = await ensureCached(docID) else { return }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: docID,
            statementTypes: [.incomeStatement]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "OperatingRevenueOILTelecommunications" && $0.value == 52_291_000_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "OperatingRevenueIncidentalELC" && $0.value == 34_057_000_000
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 86_348_000_000)
        #expect(values.salesLabel == "営業収益")
        #expect(values.operatingProfit == 18_693_000_000)
        #expect(values.netProfit == 13_217_000_000)
    }

    /// 本表が事業別内訳のときだけ Summary 合計を載せる。RWY 合計がある会社には載せない。
    @Test func overlayStatementSalesSummaryTotalsOnlyWhenComponentWouldWin() {
        let tagElements: XbrlTagElements = [
            "OperatingRevenue1SummaryOfBusinessResults": [
                "CurrentYearDuration": 86_348_000_000,
                "Prior1YearDuration": 84_314_000_000,
            ]
        ]

        var componentFS = makeFieldSet(
            ("OperatingRevenueOILTelecommunications", 52_291_000_000.0, 50_695_000_000.0)
        )
        StatementFinancialsResolver.overlayStatementSalesSummaryTotals(
            &componentFS, tagElements: tagElements)
        let afterComponent = resolveNetSales(componentFS)
        #expect(afterComponent.tag == "OperatingRevenue1SummaryOfBusinessResults")
        #expect(afterComponent.current == 86_348_000_000)

        var rwyFS = makeFieldSet(
            ("OperatingRevenueRWY", 1_086_179_000_000.0, nil)
        )
        StatementFinancialsResolver.overlayStatementSalesSummaryTotals(
            &rwyFS, tagElements: tagElements)
        let afterRWY = resolveNetSales(rwyFS)
        #expect(afterRWY.tag == "OperatingRevenueRWY")
        #expect(afterRWY.current == 1_086_179_000_000.0)
        #expect(rwyFS["OperatingRevenue1SummaryOfBusinessResults"] == nil)
    }

    /// 東急 S100YE63: `OperatingRevenueRWY` は会社全体合計。Summary 合計を載せても売上は変わらない。
    @Test func tokyuS100YE63SummarySalesStaysOperatingRevenueRWY() async throws {
        let docID = "S100YE63"
        guard let xbrlDir = await ensureCached(docID) else { return }
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 1_086_179_000_000)
        #expect(values.salesLabel == "営業収益")
        #expect(values.operatingProfit == 103_193_000_000)
    }

    /// 東電HD S100YIHR: `OperatingRevenueELE` は会社全体合計（電気+その他）。内訳にしない。
    @Test func tepcoS100YIHRSummarySalesStaysOperatingRevenueELE() async throws {
        let docID = "S100YIHR"
        guard let xbrlDir = await ensureCached(docID) else { return }
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 6_328_574_000_000)
        #expect(values.salesLabel == "営業収益")
        #expect(values.operatingProfit == 337_689_000_000)
    }

    /// 9127 玉井商船 / S100Y90D。本表は海運業収益合計 4,997.823 とその他事業収益 124.204 に分かれ、
    /// 営業収益合計タグは無い。合算して連結営業収益 5,122.027 百万円にする。
    @Test func tamaiS100Y90DSummarySalesSumsShippingAndOtherBusinessRevenue() async throws {
        let docID = "S100Y90D"
        guard let xbrlDir = await ensureCached(docID) else { return }

        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir,
            docID: docID,
            statementTypes: [.incomeStatement]
        ) else {
            Issue.record("resolveFromXBRL failed for \(docID)")
            return
        }

        #expect(
            year.incomeStatement.contains {
                $0.tag == "ShippingBusinessRevenueWAT" && $0.value == 4_997_823_000
            })
        #expect(
            year.incomeStatement.contains {
                $0.tag == "OtherBusinessRevenueWAT" && $0.value == 124_204_000
            })
        #expect(!year.incomeStatement.contains { $0.tag == "OperatingRevenue1" })
        #expect(
            !year.incomeStatement.contains {
                $0.tag == "ShippingBusinessRevenueAndOtherOperatingRevenueWAT"
            })

        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 5_122_027_000)
        #expect(values.salesLabel == "営業収益")
        #expect(values.operatingProfit == 657_778_000)
        #expect(values.netProfit == 774_625_000)
    }

    /// 9107 川崎汽船 / S100YC6B。本表合計 `ShippingBusinessRevenueAndOtherOperatingRevenueWAT` を使う。
    /// 内訳合算に落とさない。
    @Test func klineS100YC6BSummarySalesStaysShippingAndOtherOperatingRevenueTotal() async throws {
        let docID = "S100YC6B"
        guard let xbrlDir = await ensureCached(docID) else { return }
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        #expect(values.sales == 1_018_364_000_000)
        #expect(values.salesLabel == "海運業収益")
    }

    /// 3382 型: 本表に売上高と営業収益が並ぶ。Summary `sales_label` は売上高のまま、
    /// geography カバー判定だけトップラインの営業収益を使う。
    @Test func geographyCoverageLabelPrefersOperatingRevenueWhenNetSalesAlsoPresent() {
        var both: FieldSet = [:]
        both["NetSales"] = FieldValue(current: 8_893_693, prior: nil)
        both["OperatingRevenue1"] = FieldValue(current: 10_430_269, prior: nil)
        #expect(
            StatementFinancialsResolver.geographyCoverageSalesLabel(
                summaryLabel: "売上高", fieldSet: both) == "営業収益")
        #expect(
            StatementFinancialsResolver.fieldSetHasDistinctNetSalesAndOperatingRevenue(both))

        var onlySales: FieldSet = [:]
        onlySales["NetSales"] = FieldValue(current: 8_893_693, prior: nil)
        #expect(
            StatementFinancialsResolver.geographyCoverageSalesLabel(
                summaryLabel: "売上高", fieldSet: onlySales) == "売上高")

        var onlyOperating: FieldSet = [:]
        onlyOperating["OperatingRevenue1"] = FieldValue(current: 10_430_269, prior: nil)
        #expect(
            StatementFinancialsResolver.geographyCoverageSalesLabel(
                summaryLabel: "営業収益", fieldSet: onlyOperating) == "営業収益")
    }
}
