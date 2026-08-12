import Testing
import Foundation
@testable import BlueTickerCore

/// EDINET XBRL キャッシュ（tmp_cache/edinet/、git 管理外）を直接読んで抽出器を動かし、
/// smoke/smoke_expected/*.json の期待値と照合するスモークテスト。
/// BLT_EDINET_API_KEY 環境変数が設定されていれば不足分を自動ダウンロードする
/// （SmokeCacheSupport）。未設定かつキャッシュも無い環境ではスキップする。
@Suite struct SmokeTests {

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
    private static let knownGaps: [String: Set<String>] = [:]

    // MARK: - 相対誤差許容度

    private static let relTol = 1e-4

    // MARK: - テスト本体

    @Test func testSmokeAll() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            print("SKIP   smoke/smoke_expected が見つかりません")
            return
        }
        await SmokeCacheSupport.ensureCached(Self.docIDs.values)

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
        #expect(failures.isEmpty, Comment(rawValue: "スモークテスト失敗:\n" + failures.map { "\($0.id): \($0.detail)" }.joined(separator: "\n")))
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
        var cfTreasuryStock: Double?
        var dividendSS: Double?
        var dividendPaidCF: Double?
        var accountsReceivable: Double?
        var inventory: Double?
        var accountsPayable: Double?
        var eps: Double?
        var issuedShares: Double?
    }

    private func extractFromXBRL(xbrlDir: URL) -> Extracted {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        var durationFS = fieldSetFromDuration(allTags)
        var instantFS = fieldSetFromInstant(allTags)

        // US-GAAP 企業: 連結 P/L・BS の値は HTML テーブルにのみ存在するため仮想タグで補完する
        // （未移行フィールド・statement 欠測時フォールバック用。本表水準値は statement 正本）
        if std == "US-GAAP" {
            for (tag, fv) in USGAAPHtml.parsePLFields(in: xbrlDir) { durationFS[tag] = fv }
            for (tag, fv) in USGAAPHtml.parseBSFields(in: xbrlDir) { instantFS[tag] = fv }
        }

        let statementMain = StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)
        let is_ = IncomeStatementExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let cf  = CashFlowExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let gp  = GrossProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std, xbrlDir: xbrlDir)
        let op  = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let bs  = BalanceSheetExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let ibd = IBDExtractor.extract(fieldSet: instantFS, accountingStandard: std, xbrlDir: xbrlDir)
        let emp = EmployeesExtractor.extract(fieldSet: instantFS, tagElements: allTags)
        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ie  = InterestExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std, xbrlDir: xbrlDir)
        let ppe = TangibleFixedAssetsExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let rd  = RDExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let cashItem = resolveItem(instantFS, tags: Xbrl.cashEquivalentsTags)
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(allTags)
        let equityAttrFS = fieldSetFromIFRSEquityAttributable(allTags)
        let cfTs = CfTreasuryStockExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let divSS = DividendSSExtractor.extract(fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS, accountingStandard: std)
        let divPaid = DividendPaidExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ar  = AccountsReceivableExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let inv = InventoryExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let ap  = AccountsPayableExtractor.extract(fieldSet: instantFS, accountingStandard: std)

        func prefer(_ statement: Double?, _ legacy: Double?) -> Double? { statement ?? legacy }

        return Extracted(
            sales:                  prefer(statementMain?.sales, is_.sales),
            operatingProfit:        prefer(
                statementMain?.operatingProfit, op.operatingProfit ?? is_.operatingProfit),
            netProfit:              prefer(statementMain?.netProfit, is_.netProfit),
            accountingStandard:     std,
            grossProfit:            gp.grossProfit,
            sga:                    op.sga,
            cfo:                    cf.cfo,
            cfi:                    cf.cfi,
            totalAssets:            prefer(statementMain?.totalAssets, bs.totalAssets),
            currentAssets:          prefer(statementMain?.currentAssets, bs.currentAssets),
            nonCurrentAssets:       prefer(statementMain?.nonCurrentAssets, bs.nonCurrentAssets),
            currentLiabilities:     prefer(statementMain?.currentLiabilities, bs.currentLiabilities),
            nonCurrentLiabilities:  prefer(
                statementMain?.nonCurrentLiabilities, bs.nonCurrentLiabilities),
            netAssets:              prefer(statementMain?.netAssets, bs.netAssets),
            ibdTotal:               ibd.total,
            pretaxIncome:           tax.pretaxIncome,
            incomeTax:              tax.incomeTax,
            effectiveTaxRate:       tax.effectiveTaxRate,
            ppeTotal:               prefer(statementMain?.ppeTotal, ppe.total),
            capex:                  StatementNotesResolver.financialsCanonicalCapex(
                xbrlDir: xbrlDir, accountingStandard: std),
            rd:                     rd.current,
            employees:              emp.current,
            cashEq:                 prefer(statementMain?.cashEquivalents, cashItem.current),
            interestExpense:        ie.current,
            cfTreasuryStock:        cfTs.current,
            dividendSS:             divSS.current,
            dividendPaidCF:         prefer(statementMain?.dividendPaidCF, divPaid.current),
            accountsReceivable:     prefer(statementMain?.accountsReceivable, ar.current),
            inventory:              prefer(statementMain?.inventory, inv.current),
            accountsPayable:        prefer(statementMain?.accountsPayable, ap.current),
            eps:                    StatementNotesResolver.financialsCanonicalEps(xbrlDir: xbrlDir),
            issuedShares:           StatementNotesResolver.financialsCanonicalIssuedShares(xbrlDir: xbrlDir)
        )
    }

    /// financials 組立の本表水準値が statement 正本から取れることを smoke 11 社で回帰する（タスク #5）。
    /// statement 解決自体が失敗した書類はスキップし、取れたフィールドは期待値と照合する。
    @Test func testFinancialsPassthroughMatchesStatementCanonical() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            print("SKIP   smoke/smoke_expected が見つかりません")
            return
        }
        await SmokeCacheSupport.ensureCached(Self.docIDs.values)

        var failures: [String] = []
        var checked = 0

        for (fixtureID, docID) in Self.docIDs.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            guard FileManager.default.fileExists(atPath: xbrlDir.path) else { continue }
            let fixturePath = fixtureDir.appendingPathComponent("\(fixtureID).json")
            guard FileManager.default.fileExists(atPath: fixturePath.path),
                  let expected = try? loadFixture(fixturePath),
                  !isAllNull(expected),
                  let statement = StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)
            else { continue }

            /// 必須フィールド: statement が必ず返し、期待値と一致すること。
            func assertRequired(_ field: String, expected exp: Double?, actual act: Double?) {
                guard let e = exp else { return }
                guard let a = act else {
                    failures.append("\(fixtureID) \(field): statement=nil expected=\(e)")
                    return
                }
                let tol = max(abs(e) * Self.relTol, 1.0)
                if abs(e - a) > tol {
                    failures.append("\(fixtureID) \(field): statement=\(a) expected=\(e)")
                }
            }
            /// 任意フィールド: statement が返したときだけ期待値と照合（欠測は旧 Extractor フォールバック）。
            func assertIfPresent(_ field: String, expected exp: Double?, actual act: Double?) {
                guard let e = exp, let a = act else { return }
                let tol = max(abs(e) * Self.relTol, 1.0)
                if abs(e - a) > tol {
                    failures.append("\(fixtureID) \(field): statement=\(a) expected=\(e)")
                }
            }

            let income = expected["income_statement"] as? [String: Any] ?? [:]
            let bs = expected["balance_sheet"] as? [String: Any] ?? [:]
            assertRequired("sales", expected: dbl(income["sales"]), actual: statement.sales)
            assertRequired(
                "operating_profit", expected: dbl(income["operating_profit"]),
                actual: statement.operatingProfit)
            assertRequired(
                "net_profit", expected: dbl(income["net_profit"]), actual: statement.netProfit)
            assertRequired(
                "total_assets", expected: dbl(bs["total_assets"]), actual: statement.totalAssets)
            assertRequired(
                "net_assets", expected: dbl(bs["net_assets"]), actual: statement.netAssets)
            assertIfPresent(
                "current_assets", expected: dbl(bs["current_assets"]),
                actual: statement.currentAssets)
            assertIfPresent(
                "non_current_assets", expected: dbl(bs["non_current_assets"]),
                actual: statement.nonCurrentAssets)
            assertIfPresent(
                "current_liabilities", expected: dbl(bs["current_liabilities"]),
                actual: statement.currentLiabilities)
            assertIfPresent(
                "non_current_liabilities", expected: dbl(bs["non_current_liabilities"]),
                actual: statement.nonCurrentLiabilities)
            assertIfPresent(
                "ppe_total",
                expected: dbl((expected["tangible_fixed_assets"] as? [String: Any])?["total"]),
                actual: statement.ppeTotal)
            assertIfPresent(
                "cash_eq", expected: dbl((expected["cash_eq"] as? [String: Any])?["current"]),
                actual: statement.cashEquivalents)
            assertIfPresent(
                "dividend_paid_cf",
                expected: dbl((expected["dividend_paid_cf"] as? [String: Any])?["current"]),
                actual: statement.dividendPaidCF)
            assertIfPresent(
                "accounts_receivable",
                expected: dbl((expected["accounts_receivable"] as? [String: Any])?["current"]),
                actual: statement.accountsReceivable)
            assertIfPresent(
                "inventory",
                expected: dbl((expected["inventory"] as? [String: Any])?["current"]),
                actual: statement.inventory)
            assertIfPresent(
                "accounts_payable",
                expected: dbl((expected["accounts_payable"] as? [String: Any])?["current"]),
                actual: statement.accountsPayable)
            checked += 1
        }

        guard checked > 0 else {
            print("SKIP   statement 正本パススルー: XBRL キャッシュなし")
            return
        }
        #expect(
            failures.isEmpty,
            Comment(rawValue: "financials↔statement 正本不一致:\n" + failures.joined(separator: "\n")))
    }

    /// financials 組立の EPS / 発行済株式が notes 正本（`per_share_information` /
    /// `issued_shares_and_capital`）と一致することを smoke 11 社で回帰する（タスク #3）。
    @Test func testFinancialsPassthroughMatchesNotesCanonical() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            print("SKIP   smoke/smoke_expected が見つかりません")
            return
        }
        await SmokeCacheSupport.ensureCached(Self.docIDs.values)

        var failures: [String] = []

        for (fixtureID, docID) in Self.docIDs.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            guard FileManager.default.fileExists(atPath: xbrlDir.path) else { continue }

            let financialsEps = StatementNotesResolver.financialsCanonicalEps(xbrlDir: xbrlDir)
            let financialsShares = StatementNotesResolver.financialsCanonicalIssuedShares(xbrlDir: xbrlDir)

            let notesEps: Double?
            switch StatementNotesResolver.resolvePerShareInformation(xbrlDir: xbrlDir) {
            case .resolved(let payload, _, _):
                notesEps = payload.items?.first(where: { $0.tag == "eps" })?.value
            default:
                notesEps = nil
            }

            let notesShares: Double?
            switch StatementNotesResolver.resolveIssuedSharesAndCapital(xbrlDir: xbrlDir) {
            case .resolved(let payload, _, _):
                notesShares = payload.issuedSharesAsOf?.issuedShares
            default:
                notesShares = nil
            }

            if financialsEps != notesEps {
                failures.append("\(fixtureID) eps: financials=\(financialsEps.map { String($0) } ?? "nil"), notes=\(notesEps.map { String($0) } ?? "nil")")
            }
            if financialsShares != notesShares {
                failures.append("\(fixtureID) issuedShares: financials=\(financialsShares.map { String($0) } ?? "nil"), notes=\(notesShares.map { String($0) } ?? "nil")")
            }
        }

        #expect(failures.isEmpty, Comment(rawValue: "financials↔notes 正本不一致:\n" + failures.joined(separator: "\n")))
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

        let cfTs = expected["cf_treasury_stock"] as? [String: Any] ?? [:]
        check("cfTreasuryStock", exp: dbl(cfTs["current"]), act: actual.cfTreasuryStock)

        let divSS = expected["dividend_ss"] as? [String: Any] ?? [:]
        check("dividendSS", exp: dbl(divSS["current"]), act: actual.dividendSS)

        let divCF = expected["dividend_paid_cf"] as? [String: Any] ?? [:]
        check("dividendPaidCF", exp: dbl(divCF["current"]), act: actual.dividendPaidCF)

        let ar = expected["accounts_receivable"] as? [String: Any] ?? [:]
        check("accountsReceivable", exp: dbl(ar["current"]), act: actual.accountsReceivable)

        let inv = expected["inventory"] as? [String: Any] ?? [:]
        check("inventory", exp: dbl(inv["current"]), act: actual.inventory)

        let ap = expected["accounts_payable"] as? [String: Any] ?? [:]
        check("accountsPayable", exp: dbl(ap["current"]), act: actual.accountsPayable)

        let perShare = expected["per_share"] as? [String: Any] ?? [:]
        check("eps",          exp: dbl(perShare["eps"]),           act: actual.eps)
        check("issuedShares", exp: dbl(perShare["issued_shares"]), act: actual.issuedShares)

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
