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
        #expect((fixture["schema_version"] as? NSNumber)?.intValue == 2)
        return try #require(fixture["cases"] as? [[String: Any]])
    }

    private func caseWithID(_ id: String) throws -> [String: Any] {
        try #require(cases().first { $0["id"] as? String == id })
    }

    private func dimensions(_ prototypeCase: [String: Any]) throws -> [[String: Any]] {
        try #require(prototypeCase["dimensions"] as? [[String: Any]])
    }

    private func items(_ container: [String: Any]) throws -> [[String: Any]] {
        try #require(container["items"] as? [[String: Any]])
    }

    private func value(_ object: [String: Any], key: String) throws -> Double {
        try #require((object[key] as? NSNumber)?.doubleValue)
    }

    private func dimensionWithID(_ id: String, in prototypeCase: [String: Any]) throws -> [String: Any] {
        try #require(dimensions(prototypeCase).first { $0["id"] as? String == id })
    }

    private func drilldownWithID(_ id: String, in prototypeCase: [String: Any]) throws -> [String: Any] {
        let drilldowns = try #require(prototypeCase["drilldowns"] as? [String: [String: Any]])
        return try #require(drilldowns[id])
    }

    private func bridges(_ prototypeCase: [String: Any]) throws -> [[String: Any]] {
        try #require(prototypeCase["bridges"] as? [[String: Any]])
    }

    private func bridgeWithID(_ id: String, in prototypeCase: [String: Any]) throws -> [String: Any] {
        try #require(bridges(prototypeCase).first { $0["id"] as? String == id })
    }

    private func rowsByLabel(_ rows: [[String: Any]], valueKey: String) throws -> [String: Double] {
        try Dictionary(uniqueKeysWithValues: rows.map {
            (try #require($0["label"] as? String), try value($0, key: valueKey))
        })
    }

    private func countedDimensionTotal(_ dimension: [String: Any]) throws -> Double {
        try items(dimension).reduce(0.0) { total, item in
            let kind = item["row_kind"] as? String
            guard kind == "segment" || kind == "reconciling" else { return total }
            return try total + value(item, key: "value")
        }
    }

    @Test func materialsUseDimensionsNotLayoutAndConserveTotals() throws {
        for prototypeCase in try cases() {
            #expect(prototypeCase["cross_axis_links_available"] as? Bool == false)
            #expect(prototypeCase["axes"] == nil)
            #expect(prototypeCase["left_axis"] == nil)
            #expect(prototypeCase["right_axis"] == nil)
            #expect(prototypeCase["default_layout"] == nil)

            let caseDimensions = try dimensions(prototypeCase)
            #expect(caseDimensions.count >= 2)
            #expect(caseDimensions.allSatisfy { ($0["id"] as? String) != "pl" })

            for dimension in caseDimensions {
                let dimensionItems = try items(dimension)
                #expect(dimension["id"] is String)
                #expect(dimension["label"] is String)
                #expect(dimension["available"] as? Bool == true)
                #expect(!dimensionItems.isEmpty)
                #expect(dimensionItems.allSatisfy {
                    $0["id"] is String
                        && $0["label"] is String
                        && $0["value"] is NSNumber
                        && ($0["row_kind"] as? String == "segment"
                            || $0["row_kind"] as? String == "reconciling")
                })
                #expect(try countedDimensionTotal(dimension) == value(dimension, key: "total"))
            }

            let totals = try caseDimensions.map { try value($0, key: "total") }
            #expect(Set(totals).count == 1)
        }
    }

    @Test func assetDimensionsMatchStatementBackedSmokeValues() throws {
        let prototypeCase = try caseWithID("assets_2802_2025")
        let smoke = try loadObject("smoke/smoke_expected/2802_2025-03-31.json")
        let balanceSheet = try #require(smoke["balance_sheet"] as? [String: Any])
        let assets = try dimensionWithID("assets", in: prototypeCase)
        let funding = try dimensionWithID("liabilities_and_equity", in: prototypeCase)

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
        let rd = try drilldownWithID("research_and_development", in: ajinomoto)

        #expect(try value(ajinomotoMetrics, key: "net_profit") == value(ajinomotoIncome, key: "net_profit"))
        #expect(try value(ajinomotoMetrics, key: "closing_equity") == value(ajinomotoBalance, key: "net_assets"))
        #expect(try value(ajinomotoMetrics, key: "share_buyback") == value(buyback, key: "current"))
        #expect(try value(ajinomotoMetrics, key: "dividends") == value(dividends, key: "current"))
        #expect(try value(ajinomotoMetrics, key: "opening_equity") == 884_448_000_000)
        #expect(try value(rd, key: "total") == 30_921_000_000)
        #expect(try items(rd).filter { $0["tag"] is String }.count == 5)
        let rdValues = try Dictionary(uniqueKeysWithValues: items(rd).map {
            (try #require($0["id"] as? String), try value($0, key: "value"))
        })
        #expect(rdValues["seasonings_and_foods"] == 8_032_000_000)
        #expect(rdValues["frozen_foods"] == 1_855_000_000)
        #expect(rdValues["healthcare_and_others"] == 11_212_000_000)
        #expect(rdValues["other_segments"] == 258_000_000)
        #expect(rdValues["unallocated_and_elimination"] == 9_562_000_000)
        #expect(rdValues["rounding_difference"] == 2_000_000)

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

    @Test func salesMaterialsSeparateEarningDimensionsFromPLBridge() throws {
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
        let taxExpense = try #require(financials["tax_expense"] as? [String: Any])

        #expect(prototypeCase["accounting_standard"] as? String == "us_gaap")
        #expect(try dimensions(prototypeCase).allSatisfy { ($0["id"] as? String) != "pl" })

        let geography = try dimensionWithID("geography", in: prototypeCase)
        let business = try dimensionWithID("business", in: prototypeCase)
        #expect(try rowsByLabel(items(geography), valueKey: "value")
            == rowsByLabel(geographySource, valueKey: "sales"))
        #expect(try rowsByLabel(items(business), valueKey: "value")
            == rowsByLabel(businessSource, valueKey: "sales"))

        let businessKinds = try Dictionary(uniqueKeysWithValues: items(business).map {
            (try #require($0["id"] as? String), try #require($0["row_kind"] as? String))
        })
        #expect(businessKinds["その他及び全社"] == "reconciling")
        #expect(businessKinds["プリンティング"] == "segment")

        let pl = try bridgeWithID("profit_and_loss", in: prototypeCase)
        #expect(pl["accounting_standard"] as? String == "us_gaap")
        #expect(try value(pl, key: "conserved_total") == value(incomeStatement, key: "sales"))
        #expect(pl["needs_review"] as? Bool == false)

        let stages = try #require(pl["stages"] as? [[String: Any]])
        for stage in stages {
            let stageItems = try items(stage)
            let stageTotal = try stageItems.reduce(0.0) { try $0 + value($1, key: "value") }
            #expect(stageTotal == (try value(stage, key: "conserved_total")))
            #expect(stageItems.allSatisfy { ($0["label"] as? String)?.contains("経常") != true })
            #expect(stageItems.allSatisfy { ($0["label"] as? String)?.contains("特別") != true })
        }

        let toGross = try #require(stages.first { $0["id"] as? String == "to_gross_profit" })
        let toOperating = try #require(stages.first { $0["id"] as? String == "to_operating_profit" })
        let toPretax = try #require(stages.first { $0["id"] as? String == "to_pretax_income" })
        let toNet = try #require(stages.first { $0["id"] as? String == "to_net_profit" })

        let grossItems = try Dictionary(uniqueKeysWithValues: items(toGross).map {
            (try #require($0["id"] as? String), $0)
        })
        let operatingItems = try Dictionary(uniqueKeysWithValues: items(toOperating).map {
            (try #require($0["id"] as? String), $0)
        })
        let pretaxItems = try Dictionary(uniqueKeysWithValues: items(toPretax).map {
            (try #require($0["id"] as? String), $0)
        })
        let netItems = try Dictionary(uniqueKeysWithValues: items(toNet).map {
            (try #require($0["id"] as? String), $0)
        })

        let sales = try value(incomeStatement, key: "sales")
        let gross = try value(grossProfit, key: "gross_profit")
        #expect(try value(grossItems["cost_of_sales"]!, key: "value") == sales - gross)
        #expect(grossItems["cost_of_sales"]?["derived"] as? Bool == true)
        #expect(try value(grossItems["gross_profit"]!, key: "value") == gross)
        #expect(try value(operatingItems["sga"]!, key: "value") == value(sga, key: "current"))
        #expect(try value(operatingItems["research_and_development"]!, key: "value")
            == value(researchDevelopment, key: "current"))
        #expect(try value(operatingItems["operating_profit"]!, key: "value")
            == value(incomeStatement, key: "operating_profit"))
        #expect(try value(toPretax, key: "conserved_total") == value(taxExpense, key: "pretax_income"))
        #expect(try value(netItems["income_tax"]!, key: "value") == value(taxExpense, key: "income_tax"))
        #expect(try value(netItems["net_profit"]!, key: "value")
            == value(incomeStatement, key: "net_profit"))
        #expect(pretaxItems["other_income_expense_net"]?["derived"] as? Bool == true)
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
