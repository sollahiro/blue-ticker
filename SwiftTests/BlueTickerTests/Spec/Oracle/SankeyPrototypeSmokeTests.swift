import Foundation
import Testing

@Suite struct SankeyPrototypeSmokeTests {
    private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    private func loadObject(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func cases() throws -> [[String: Any]] {
        let fixture = try loadObject("smoke/sankey_prototype_expected.json")
        #expect((fixture["schema_version"] as? NSNumber)?.intValue == 1)
        return try #require(fixture["cases"] as? [[String: Any]])
    }

    private func caseWithID(_ id: String) throws -> [String: Any] {
        try #require(cases().first { $0["id"] as? String == id })
    }

    private func axes(_ prototypeCase: [String: Any]) throws -> [[String: Any]] {
        try #require(prototypeCase["axes"] as? [[String: Any]])
    }

    private func items(_ axis: [String: Any]) throws -> [[String: Any]] {
        try #require(axis["items"] as? [[String: Any]])
    }

    private func value(_ object: [String: Any], key: String) throws -> Double {
        try #require((object[key] as? NSNumber)?.doubleValue)
    }

    private func axisWithID(_ id: String, in prototypeCase: [String: Any]) throws -> [String: Any] {
        try #require(axes(prototypeCase).first { $0["id"] as? String == id })
    }

    private func rowsByLabel(_ rows: [[String: Any]], valueKey: String) throws -> [String: Double] {
        try Dictionary(uniqueKeysWithValues: rows.map {
            (try #require($0["label"] as? String), try value($0, key: valueKey))
        })
    }

    @Test func axesUseOneReplaceableValueShapeAndConserveTheirTotals() throws {
        for prototypeCase in try cases() {
            #expect(prototypeCase["cross_axis_links_available"] as? Bool == false)
            let caseAxes = try axes(prototypeCase)
            #expect(caseAxes.count >= 2)

            for axis in caseAxes {
                let axisItems = try items(axis)
                #expect(axis["id"] is String)
                #expect(axis["label"] is String)
                #expect(!axisItems.isEmpty)
                #expect(axisItems.allSatisfy {
                    $0["id"] is String && $0["label"] is String && $0["value"] is NSNumber
                })

                let itemTotal = try axisItems.reduce(0.0) { total, item in
                    total + (try value(item, key: "value"))
                }
                #expect(itemTotal == (try value(axis, key: "total")))
            }

        }
    }

    @Test func assetAxesMatchStatementBackedSmokeValues() throws {
        let prototypeCase = try caseWithID("assets_2802_2025")
        let smoke = try loadObject("smoke/smoke_expected/2802_2025-03-31.json")
        let balanceSheet = try #require(smoke["balance_sheet"] as? [String: Any])
        let assets = try axisWithID("assets", in: prototypeCase)
        let funding = try axisWithID("liabilities_and_equity", in: prototypeCase)

        let assetItems = try Dictionary(uniqueKeysWithValues: items(assets).map {
            (try #require($0["id"] as? String), try value($0, key: "value"))
        })
        let fundingItems = try Dictionary(uniqueKeysWithValues: items(funding).map {
            (try #require($0["id"] as? String), try value($0, key: "value"))
        })

        #expect(try value(assets, key: "total") == value(balanceSheet, key: "total_assets"))
        #expect(assetItems["current_assets"] == (try value(balanceSheet, key: "current_assets")))
        #expect(assetItems["non_current_assets"] == (try value(balanceSheet, key: "non_current_assets")))
        #expect(fundingItems["current_liabilities"] == (try value(balanceSheet, key: "current_liabilities")))
        #expect(fundingItems["non_current_liabilities"] == (try value(balanceSheet, key: "non_current_liabilities")))
        #expect(fundingItems["equity"] == (try value(balanceSheet, key: "net_assets")))
    }

    @Test func deepDiveMetricsMatchSmokeValuesAndRDBreakdown() throws {
        let ajinomoto = try caseWithID("assets_2802_2025")
        let ajinomotoSmoke = try loadObject("smoke/smoke_expected/2802_2025-03-31.json")
        let ajinomotoMetrics = try #require(ajinomoto["metrics"] as? [String: Any])
        let ajinomotoIncome = try #require(ajinomotoSmoke["income_statement"] as? [String: Any])
        let ajinomotoBalance = try #require(ajinomotoSmoke["balance_sheet"] as? [String: Any])
        let buyback = try #require(ajinomotoSmoke["share_buyback"] as? [String: Any])
        let dividends = try #require(ajinomotoSmoke["dividend_ss"] as? [String: Any])
        let rd = try axisWithID("research_and_development", in: ajinomoto)

        #expect(try value(ajinomotoMetrics, key: "net_profit") == value(ajinomotoIncome, key: "net_profit"))
        #expect(try value(ajinomotoMetrics, key: "closing_equity") == value(ajinomotoBalance, key: "net_assets"))
        #expect(try value(ajinomotoMetrics, key: "share_buyback") == value(buyback, key: "current"))
        #expect(try value(ajinomotoMetrics, key: "dividends") == value(dividends, key: "current"))
        #expect(try value(ajinomotoMetrics, key: "opening_equity") == 884_448_000_000)
        #expect(try value(rd, key: "total") == 30_921_000_000)
        #expect(items(rd).filter { $0["tag"] is String }.count == 5)

        let canon = try caseWithID("sales_7751_2025")
        let canonSmoke = try loadObject("smoke/smoke_expected/7751_2025-12-31.json")
        let canonMetrics = try #require(canon["metrics"] as? [String: Any])
        let canonIncome = try #require(canonSmoke["income_statement"] as? [String: Any])
        let grossProfit = try #require(canonSmoke["gross_profit"] as? [String: Any])
        let sga = try #require(canonSmoke["sga"] as? [String: Any])
        let researchDevelopment = try #require(canonSmoke["research_development"] as? [String: Any])
        let taxExpense = try #require(canonSmoke["tax_expense"] as? [String: Any])

        #expect(try value(canonMetrics, key: "gross_profit") == value(grossProfit, key: "gross_profit"))
        #expect(try value(canonMetrics, key: "sga") == value(sga, key: "current"))
        #expect(try value(canonMetrics, key: "research_and_development")
            == value(researchDevelopment, key: "current"))
        #expect(try value(canonMetrics, key: "operating_profit")
            == value(canonIncome, key: "operating_profit"))
        #expect(try value(canonMetrics, key: "pretax_income") == value(taxExpense, key: "pretax_income"))
        #expect(try value(canonMetrics, key: "income_tax") == value(taxExpense, key: "income_tax"))
        #expect(try value(canonMetrics, key: "net_profit") == value(canonIncome, key: "net_profit"))
    }

    @Test func salesAxesMatchGeographyBusinessAndPLSmokeValues() throws {
        let prototypeCase = try caseWithID("sales_7751_2025")
        let geographyFixture = try loadObject("smoke/breakdown_geography_expected.json")
        let businessFixture = try loadObject("smoke/breakdown_business_expected.json")
        let financials = try loadObject("smoke/smoke_expected/7751_2025-12-31.json")

        let geographySource = try #require(
            (geographyFixture["S100XTLJ"] as? [String: Any])?["rows"] as? [[String: Any]])
        let businessSource = try #require(
            (businessFixture["S100XTLJ"] as? [String: Any])?["rows"] as? [[String: Any]])
        let incomeStatement = try #require(financials["income_statement"] as? [String: Any])
        let grossProfit = try #require(financials["gross_profit"] as? [String: Any])
        let sga = try #require(financials["sga"] as? [String: Any])
        let researchDevelopment = try #require(financials["research_development"] as? [String: Any])

        let geography = try axisWithID("geography", in: prototypeCase)
        let business = try axisWithID("business", in: prototypeCase)
        let pl = try axisWithID("pl", in: prototypeCase)

        #expect(try rowsByLabel(items(geography), valueKey: "value")
            == rowsByLabel(geographySource, valueKey: "sales"))
        #expect(try rowsByLabel(items(business), valueKey: "value")
            == rowsByLabel(businessSource, valueKey: "sales"))
        #expect(try value(pl, key: "total") == value(incomeStatement, key: "sales"))
        let plItems = try Dictionary(uniqueKeysWithValues: items(pl).map {
            (try #require($0["id"] as? String), try value($0, key: "value"))
        })
        let sales = try value(incomeStatement, key: "sales")
        let gross = try value(grossProfit, key: "gross_profit")
        #expect(plItems["cost_of_sales"] == sales - gross)
        #expect(plItems["sga"] == (try value(sga, key: "current")))
        #expect(plItems["research_and_development"] == (try value(researchDevelopment, key: "current")))
        #expect(plItems["operating_profit"] == (try value(incomeStatement, key: "operating_profit")))
    }

    @Test func operatingProfitThreeAxesAreBlockedByMissingGeographyProfit() throws {
        let geographyFixture = try loadObject("smoke/breakdown_geography_expected.json")
        let businessFixture = try loadObject("smoke/breakdown_business_expected.json")
        let financials = try loadObject("smoke/smoke_expected/7751_2025-12-31.json")
        let geographyRows = try #require(
            (geographyFixture["S100XTLJ"] as? [String: Any])?["rows"] as? [[String: Any]])
        let businessRows = try #require(
            (businessFixture["S100XTLJ"] as? [String: Any])?["rows"] as? [[String: Any]])
        let incomeStatement = try #require(financials["income_statement"] as? [String: Any])

        #expect(geographyRows.allSatisfy { $0["profit"] == nil })
        let segmentProfit = try businessRows.reduce(0.0) { total, row in
            total + (try value(row, key: "profit"))
        }
        let operatingProfit = try value(incomeStatement, key: "operating_profit")
        #expect(segmentProfit == 454_479_000_000)
        #expect(operatingProfit == 455_390_000_000)
        // 開示表の「消去」911百万円を足すと事業別→PLは保存する。未抽出なのは地域別利益。
        let disclosedElimination = 911_000_000.0
        #expect(segmentProfit + disclosedElimination == operatingProfit)
    }
}
