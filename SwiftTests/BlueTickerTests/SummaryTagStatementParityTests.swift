import Foundation
import Testing

@testable import BlueTickerCore

/// 主要な経営指標等（`*SummaryOfBusinessResults`）と本表由来の financials 値が、両方あるときは一致する。
/// CF だけでなく純資産（資本合計）・総資産・純利益・税引前利益・売上・現金同等物も見る。
/// US-GAAP は円単位で完全一致。J-GAAP / IFRS は経営指標等が百万円・本表が千円のことがあるため
/// 百万円未満の差（端数切捨て）だけ許す。
@Suite struct SummaryTagStatementParityTests {
    private typealias Field = (name: String, tags: [String])

    private static func value(_ name: String, _ v: StatementFinancialsValues) -> Double? {
        switch name {
        case "cfo": v.cfo
        case "cfi": v.cfi
        case "net_assets": v.netAssets
        case "total_assets": v.totalAssets
        case "net_profit": v.netProfit
        case "pretax_income": v.pretaxIncome
        case "operating_profit": v.operatingProfit
        case "sales": v.sales
        case "cash_equivalents": v.cashEquivalents
        default: nil
        }
    }

    private static let usgaapFields: [Field] = [
        ("cfo", ["CashFlowsFromUsedInOperatingActivitiesUSGAAPSummaryOfBusinessResults"]),
        ("cfi", ["CashFlowsFromUsedInInvestingActivitiesUSGAAPSummaryOfBusinessResults"]),
        ("net_assets", ["EquityIncludingPortionAttributableToNonControllingInterestUSGAAPSummaryOfBusinessResults"]),
        ("total_assets", ["TotalAssetsUSGAAPSummaryOfBusinessResults"]),
        ("net_profit", ["NetIncomeLossAttributableToOwnersOfParentUSGAAPSummaryOfBusinessResults"]),
        ("pretax_income", ["ProfitLossBeforeTaxUSGAAPSummaryOfBusinessResults"]),
        ("operating_profit", ["OperatingIncomeLossUSGAAPSummaryOfBusinessResults"]),
        ("sales", ["RevenuesUSGAAPSummaryOfBusinessResults"]),
        ("cash_equivalents", ["CashAndCashEquivalentsUSGAAPSummaryOfBusinessResults"]),
    ]

    private static let ifrsFields: [Field] = [
        ("cfo", ["CashFlowsFromUsedInOperatingActivitiesIFRSSummaryOfBusinessResults"]),
        ("cfi", ["CashFlowsFromUsedInInvestingActivitiesIFRSSummaryOfBusinessResults"]),
        ("net_assets", ["TotalEquityIFRSSummaryOfBusinessResults"]),
        ("total_assets", ["TotalAssetsIFRSSummaryOfBusinessResults"]),
        ("net_profit", ["ProfitLossAttributableToOwnersOfParentIFRSSummaryOfBusinessResults"]),
        ("pretax_income", ["ProfitLossBeforeTaxIFRSSummaryOfBusinessResults"]),
        ("sales", ["RevenueIFRSSummaryOfBusinessResults"]),
        ("cash_equivalents", ["CashAndCashEquivalentsIFRSSummaryOfBusinessResults"]),
    ]

    private static let jgaapFields: [Field] = [
        ("cfo", ["NetCashProvidedByUsedInOperatingActivitiesSummaryOfBusinessResults"]),
        ("cfi", ["NetCashProvidedByUsedInInvestingActivitiesSummaryOfBusinessResults"]),
        ("net_assets", ["NetAssetsSummaryOfBusinessResults"]),
        ("total_assets", ["TotalAssetsSummaryOfBusinessResults"]),
        ("net_profit", ["ProfitLossAttributableToOwnersOfParentSummaryOfBusinessResults"]),
        ("sales", ["NetSalesSummaryOfBusinessResults"]),
        ("cash_equivalents", ["CashAndCashEquivalentsSummaryOfBusinessResults"]),
    ]

    /// US-GAAP 7 社（ラベル揺れ 4 社＋修正前から取れていた 3 社）、野村の旧ラベル期、
    /// ソニー 6758 の米国基準期（2021 年 3 月期）、一般ケースとして IFRS（日立）と J-GAAP（ディスコ）。
    static let docs: [String] = [
        "S100YC5C", "S100YD25", "S100YG5L", "S100R773",
        "S100YIBH", "S100YG81", "S100XTLJ",
        "S100VXTD", "S100LM4N",
        "S100YGBO", "S100YC6I",
    ]

    /// 本表パーサー側の既知の欠落（このテストの対象外の既存課題）。直ったら known issue が外れて気付ける。
    /// ソニー 2021 年 3 月期: 売上は「売上高及び営業収入」の無ラベル合計行を拾えず「純売上高」になる。
    private static let knownSalesGaps: Set<String> = ["S100LM4N"]

    private func ensureCached(_ docID: String) async -> URL? {
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        await SmokeCacheSupport.ensureCached([docID])
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし")
            return nil
        }
        return xbrlDir
    }

    private static func summaryValues(_ xbrlDir: URL) -> [String: Double] {
        let elements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
            .filter { $0.key.hasSuffix("SummaryOfBusinessResults") }
        let duration = fieldSetFromDuration(elements)
        let instant = fieldSetFromInstant(elements)
        var out: [String: Double] = [:]
        for tag in elements.keys {
            if let v = duration[tag]?.current ?? instant[tag]?.current { out[tag] = v }
        }
        return out
    }

    @Test(arguments: docs)
    func summaryTagEqualsStatementValueWhereBothExist(docID: String) async throws {
        guard let xbrlDir = await ensureCached(docID) else { return }
        let elements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let standard = detectAccountingStandard(elements)
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        let summary = Self.summaryValues(xbrlDir)
        let (fields, tolerance): ([Field], Double) =
            switch standard {
            case "US-GAAP": (Self.usgaapFields, 0.5)
            case "IFRS": (Self.ifrsFields, Financial.millionYen)
            default: (Self.jgaapFields, Financial.millionYen)
            }
        var compared: [String] = []
        for field in fields {
            guard let s = field.tags.lazy.compactMap({ summary[$0] }).first,
                let v = Self.value(field.name, values)
            else { continue }
            compared.append(field.name)
            if field.name == "sales", Self.knownSalesGaps.contains(docID) {
                withKnownIssue("\(docID) sales: 本表の無ラベル合計行（既存課題）") {
                    #expect(abs(s - v) < tolerance, "\(docID) \(field.name): summary \(s) statement \(v)")
                }
                continue
            }
            #expect(abs(s - v) < tolerance, "\(docID) \(field.name): summary \(s) statement \(v)")
        }
        // CF と総資産は全社で両方そろう（比較が空振りしていないこと）。
        #expect(compared.contains("cfo") && compared.contains("cfi") && compared.contains("total_assets"),
                "\(docID) compared only \(compared)")
    }

    /// 純資産（資本合計）も比較できること。ソニー 2021 年 3 月期は本表パーサーが資本の部を
    /// 落とすため（既存課題）known issue。
    @Test(arguments: docs)
    func equityIsComparedWhereSummaryHasIt(docID: String) async throws {
        guard let xbrlDir = await ensureCached(docID) else { return }
        let summary = Self.summaryValues(xbrlDir)
        let tags = Self.usgaapFields[2].tags + Self.ifrsFields[2].tags + Self.jgaapFields[2].tags
        guard tags.contains(where: { summary[$0] != nil }) else { return }
        let values = try #require(StatementFinancialsResolver.resolve(xbrlDir: xbrlDir))
        if docID == "S100LM4N" {
            withKnownIssue("ソニー 2021 年 3 月期: 資本の部が statement 行に無い（既存課題）") {
                #expect(values.netAssets != nil)
            }
        } else {
            #expect(values.netAssets != nil, "\(docID) net_assets is nil")
        }
    }
}
