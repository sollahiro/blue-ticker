import XCTest
@testable import BlueTicker

/// Python smoke/check.py に相当する Swift 版スモークテスト。
/// EDINET XBRL キャッシュ（ローカル）を直接読んで抽出器を動かし、
/// smoke/smoke_expected/*.json の期待値と照合する。
/// Keychain・API キー不要。
final class SmokeTests: XCTestCase {

    // MARK: - Fixture → docID マッピング

    private static let docIDs: [String: String] = [
        "2802_2025-03-31": "S100VXJA",  // 味の素 IFRS
        "2871_2025-03-31": "S100VYA0",  // ニチレイ J-GAAP
        "3490_2025-02-28": "S100VU4O",  // AZplanning J-GAAP
        "4901_2025-03-31": "S100W3XJ",  // 富士フイルム US-GAAP
        "6103_2025-03-31": "S100W043",  // オークマ J-GAAP
        "6326_2025-12-31": "S100XR0M",  // クボタ IFRS
        "7269_2025-03-31": "S100W4MT",  // スズキ IFRS
        "7422_2025-12-20": "S100XRD8",  // 東邦レマック J-GAAP
        "7751_2025-12-31": "S100XTLJ",  // キヤノン US-GAAP
        "8306_2025-03-31": "S100W4FB",  // 三菱UFJ J-GAAP
        "8316_2025-03-31": "S100W0S7",  // 三井住友 J-GAAP
    ]

    // MARK: - 既知の実装ギャップ（対象フィールドの比較をスキップ）
    // fixtureID -> スキップするフィールド名のセット
    private static let knownGaps: [String: Set<String>] = [
        // IFRS: リース負債の HTML 解析未実装のため IBD が低くなる
        "2802_2025-03-31": ["ibdTotal"],
        "6326_2025-12-31": ["ibdTotal"],
        "7269_2025-03-31": ["ibdTotal"],
        // US-GAAP: 連結 PL/BS が HTML テーブルにあり Swift では未解析
        "4901_2025-03-31": ["sales", "operatingProfit", "netProfit",
                             "totalAssets", "currentAssets", "nonCurrentAssets",
                             "currentLiabilities", "nonCurrentLiabilities", "netAssets",
                             "grossProfit", "sga", "ibdTotal", "interestExpense",
                             "pretaxIncome", "incomeTax", "effectiveTaxRate",
                             "ppeTotal", "capex", "rd"],
        "7751_2025-12-31": ["sales", "operatingProfit", "netProfit",
                             "totalAssets", "currentAssets", "nonCurrentAssets",
                             "currentLiabilities", "nonCurrentLiabilities", "netAssets",
                             "grossProfit", "sga", "ibdTotal", "interestExpense",
                             "pretaxIncome", "incomeTax", "effectiveTaxRate",
                             "ppeTotal", "capex", "rd"],
    ]

    // MARK: - 相対誤差許容度

    private static let relTol = 1e-4

    // MARK: - テスト本体

    func testSmokeAll() throws {
        let sourceURL = URL(fileURLWithPath: #file)
        let projectRoot = sourceURL
            .deletingLastPathComponent()  // BlueTickerTests
            .deletingLastPathComponent()  // SwiftTests
            .deletingLastPathComponent()  // project root
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")

        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("smoke/smoke_expected が見つかりません")
        }

        let fixtures = try FileManager.default.contentsOfDirectory(at: fixtureDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var results: [(id: String, status: String, detail: String)] = []

        for fixturePath in fixtures {
            let fixtureID = fixturePath.deletingPathExtension().lastPathComponent

            // docID が登録されていないフィクスチャはスキップ
            guard let docID = Self.docIDs[fixtureID] else {
                results.append((fixtureID, "SKIP", "docID 未登録"))
                continue
            }

            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
                results.append((fixtureID, "SKIP", "XBRL キャッシュなし: \(docID)_xbrl"))
                continue
            }

            // 期待値ロード
            let expected = try loadFixture(fixturePath)
            let name = expected["name"] as? String ?? fixtureID

            // 全フィールドが null の場合はスキップ（例: 2871_2026-12-31）
            if isAllNull(expected) {
                results.append((fixtureID, "SKIP", "全フィールドが null"))
                continue
            }

            // Swift 抽出
            let actual = extractFromXBRL(xbrlDir: xbrlDir)

            // 比較
            let gaps = Self.knownGaps[fixtureID] ?? []
            let diffs = compare(expected: expected, actual: actual, fixtureID: fixtureID, gaps: gaps)

            if diffs.isEmpty {
                results.append((fixtureID, "OK", name))
            } else {
                let detail = diffs.map { "  \($0)" }.joined(separator: "\n")
                results.append((fixtureID, "DIFF", "\(name)\n\(detail)"))
            }
        }

        // 結果表示
        for r in results {
            print("\(r.status.padding(toLength: 6, withPad: " ", startingAt: 0)) \(r.id): \(r.detail)")
        }

        let failures = results.filter { $0.status == "DIFF" }
        XCTAssert(failures.isEmpty,
                  "スモークテスト失敗:\n" + failures.map { "\($0.id): \($0.detail)" }.joined(separator: "\n"))
    }

    // MARK: - XBRL 抽出

    private struct Extracted {
        var sales: Double?
        var operatingProfit: Double?
        var netProfit: Double?
        var accountingStandard: String?
        var grossProfit: Double?
        var sga: Double?
        var cfo: Double?
        var cfi: Double?
        var totalAssets: Double?
        var currentAssets: Double?
        var nonCurrentAssets: Double?
        var currentLiabilities: Double?
        var nonCurrentLiabilities: Double?
        var netAssets: Double?
        var ibdTotal: Double?
        var pretaxIncome: Double?
        var incomeTax: Double?
        var effectiveTaxRate: Double?
        var ppeTotal: Double?
        var capex: Double?
        var rd: Double?
        var employees: Double?
        var cashEq: Double?
        var interestExpense: Double?
        var cfoRaw: Double?
        var cfiRaw: Double?
    }

    private func extractFromXBRL(xbrlDir: URL) -> Extracted {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        let durationFS = fieldSetFromDuration(allTags)
        let instantFS = fieldSetFromInstant(allTags)

        let is_ = IncomeStatementExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let cf  = CashFlowExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let gp  = GrossProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let op  = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let bs  = BalanceSheetExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let ibd = IBDExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let emp = EmployeesExtractor.extract(fieldSet: instantFS, tagElements: allTags)
        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ie  = InterestExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ppe = TangibleFixedAssetsExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let capex = CapexExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let rd  = RDExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let cashItem = resolveItem(instantFS, tags: Xbrl.cashEquivalentsTags)

        let opProfit = op.operatingProfit ?? is_.operatingProfit

        return Extracted(
            sales:                  is_.sales,
            operatingProfit:        opProfit,
            netProfit:              is_.netProfit,
            accountingStandard:     std,
            grossProfit:            gp.grossProfit,
            sga:                    op.sga,
            cfo:                    cf.cfo,
            cfi:                    cf.cfi,
            totalAssets:            bs.totalAssets,
            currentAssets:          bs.currentAssets,
            nonCurrentAssets:       bs.nonCurrentAssets,
            currentLiabilities:     bs.currentLiabilities,
            nonCurrentLiabilities:  bs.nonCurrentLiabilities,
            netAssets:              bs.netAssets,
            ibdTotal:               ibd.total,
            pretaxIncome:           tax.pretaxIncome,
            incomeTax:              tax.incomeTax,
            effectiveTaxRate:       tax.effectiveTaxRate,
            ppeTotal:               ppe.total,
            capex:                  capex.current,
            rd:                     rd.current,
            employees:              emp.current,
            cashEq:                 cashItem.current,
            interestExpense:        ie.current
        )
    }

    // MARK: - 比較

    private func compare(
        expected: [String: Any],
        actual: Extracted,
        fixtureID: String,
        gaps: Set<String>
    ) -> [String] {
        var diffs: [String] = []

        func check(_ field: String, exp: Double?, act: Double?) {
            guard !gaps.contains(field) else { return }
            guard let e = exp else { return }  // 期待値 nil はチェックしない
            guard let a = act else {
                diffs.append("\(field): expected \(fmt(e)), got nil")
                return
            }
            if e == 0 {
                if abs(a) > 1 { diffs.append("\(field): expected 0, got \(fmt(a))") }
            } else if abs(a - e) / abs(e) > Self.relTol {
                diffs.append("\(field): expected \(fmt(e)), got \(fmt(a)) (diff \(pct(a, e)))")
            }
        }

        let is_ = expected["income_statement"] as? [String: Any] ?? [:]
        check("sales",            exp: dbl(is_["sales"]),            act: actual.sales)
        check("operatingProfit",  exp: dbl(is_["operating_profit"]), act: actual.operatingProfit)
        check("netProfit",        exp: dbl(is_["net_profit"]),       act: actual.netProfit)

        let gp = expected["gross_profit"] as? [String: Any] ?? [:]
        check("grossProfit", exp: dbl(gp["gross_profit"]), act: actual.grossProfit)

        let sga = expected["sga"] as? [String: Any] ?? [:]
        check("sga", exp: dbl(sga["current"]), act: actual.sga)

        let cf = expected["cash_flow"] as? [String: Any] ?? [:]
        check("cfo", exp: dbl(cf["cfo"]), act: actual.cfo)
        check("cfi", exp: dbl(cf["cfi"]), act: actual.cfi)

        let bs = expected["balance_sheet"] as? [String: Any] ?? [:]
        check("totalAssets",         exp: dbl(bs["total_assets"]),          act: actual.totalAssets)
        check("currentAssets",       exp: dbl(bs["current_assets"]),        act: actual.currentAssets)
        check("nonCurrentAssets",    exp: dbl(bs["non_current_assets"]),    act: actual.nonCurrentAssets)
        check("currentLiabilities",  exp: dbl(bs["current_liabilities"]),   act: actual.currentLiabilities)
        check("nonCurrentLiabilities", exp: dbl(bs["non_current_liabilities"]), act: actual.nonCurrentLiabilities)
        check("netAssets",           exp: dbl(bs["net_assets"]),            act: actual.netAssets)

        let ibd = expected["interest_bearing_debt"] as? [String: Any] ?? [:]
        check("ibdTotal", exp: dbl(ibd["total"]), act: actual.ibdTotal)

        let tax = expected["tax_expense"] as? [String: Any] ?? [:]
        check("pretaxIncome",    exp: dbl(tax["pretax_income"]),  act: actual.pretaxIncome)
        check("incomeTax",       exp: dbl(tax["income_tax"]),     act: actual.incomeTax)
        check("effectiveTaxRate", exp: dbl(tax["effective_tax_rate"]), act: actual.effectiveTaxRate)

        let ppe = expected["tangible_fixed_assets"] as? [String: Any] ?? [:]
        check("ppeTotal", exp: dbl(ppe["total"]), act: actual.ppeTotal)

        let capex = expected["capital_expenditure"] as? [String: Any] ?? [:]
        check("capex", exp: dbl(capex["current"]), act: actual.capex)

        let rd = expected["research_development"] as? [String: Any] ?? [:]
        check("rd", exp: dbl(rd["current"]), act: actual.rd)

        let cashEq = expected["cash_eq"] as? [String: Any] ?? [:]
        check("cashEq", exp: dbl(cashEq["current"]), act: actual.cashEq)

        let ie = expected["interest_expense"] as? [String: Any] ?? [:]
        check("interestExpense", exp: dbl(ie["current"]), act: actual.interestExpense)

        return diffs
    }

    // MARK: - Helpers

    private func loadFixture(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func isAllNull(_ fixture: [String: Any]) -> Bool {
        for (key, val) in fixture {
            if key.hasPrefix("_") || key == "code" || key == "name" || key == "fy_end" { continue }
            if let d = val as? [String: Any] {
                if d.values.contains(where: { !($0 is NSNull) }) { return false }
            } else if !(val is NSNull) {
                return false
            }
        }
        return true
    }

    private func dbl(_ v: Any?) -> Double? {
        switch v {
        case let n as Double: return n
        case let n as Int:    return Double(n)
        case is NSNull:       return nil
        default:              return nil
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.0f", v) }

    private func pct(_ a: Double, _ e: Double) -> String {
        String(format: "%+.2f%%", (a - e) / abs(e) * 100)
    }
}
