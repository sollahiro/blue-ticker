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
        var shareBuyback: Double?
    }

    private func extractFromXBRL(xbrlDir: URL) -> Extracted {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        var durationFS = fieldSetFromDuration(allTags)
        var instantFS = fieldSetFromInstant(allTags)

        // US-GAAP: 未移行フィールド（GP/SGA/IBD/税等）用に USGAAPHtml 仮想タグを注入。
        // 本表水準値（#5）は statement 正本のみ（#5b-1: 旧 Extractor フォールバックなし）。
        if std == "US-GAAP" {
            for (tag, fv) in USGAAPHtml.parsePLFields(in: xbrlDir) { durationFS[tag] = fv }
            for (tag, fv) in USGAAPHtml.parseBSFields(in: xbrlDir) { instantFS[tag] = fv }
        }

        let statementMain = StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)
        let cf  = CashFlowExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let gp  = GrossProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std, xbrlDir: xbrlDir)
        let op  = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ibd = IBDExtractor.extract(fieldSet: instantFS, accountingStandard: std, xbrlDir: xbrlDir)
        let emp = EmployeesExtractor.extract(fieldSet: instantFS, tagElements: allTags)
        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ie  = InterestExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std, xbrlDir: xbrlDir)
        let rd  = RDExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(allTags)
        let equityAttrFS = fieldSetFromIFRSEquityAttributable(allTags)
        let cfTs = CfTreasuryStockExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let divSS = DividendSSExtractor.extract(fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS, accountingStandard: std)
        let buyback = ShareBuybackExtractor.extract(
            fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS,
            accountingStandard: std)

        return Extracted(
            sales:                  statementMain?.sales,
            operatingProfit:        statementMain?.operatingProfit,
            netProfit:              statementMain?.netProfit,
            accountingStandard:     std,
            grossProfit:            gp.grossProfit,
            sga:                    op.sga,
            cfo:                    cf.cfo,
            cfi:                    cf.cfi,
            totalAssets:            statementMain?.totalAssets,
            currentAssets:          statementMain?.currentAssets,
            nonCurrentAssets:       statementMain?.nonCurrentAssets,
            currentLiabilities:     statementMain?.currentLiabilities,
            nonCurrentLiabilities:  statementMain?.nonCurrentLiabilities,
            netAssets:              statementMain?.netAssets,
            ibdTotal:               ibd.total,
            pretaxIncome:           tax.pretaxIncome,
            incomeTax:              tax.incomeTax,
            effectiveTaxRate:       tax.effectiveTaxRate,
            ppeTotal:               statementMain?.ppeTotal,
            capex:                  StatementNotesResolver.financialsCanonicalCapex(
                xbrlDir: xbrlDir, accountingStandard: std),
            rd:                     rd.current,
            employees:              emp.current,
            cashEq:                 statementMain?.cashEquivalents,
            interestExpense:        ie.current,
            cfTreasuryStock:        cfTs.current,
            dividendSS:             divSS.current,
            dividendPaidCF:         statementMain?.dividendPaidCF,
            accountsReceivable:     statementMain?.accountsReceivable,
            inventory:              statementMain?.inventory,
            accountsPayable:        statementMain?.accountsPayable,
            eps:                    StatementNotesResolver.financialsCanonicalEps(xbrlDir: xbrlDir),
            issuedShares:           StatementNotesResolver.financialsCanonicalIssuedShares(xbrlDir: xbrlDir),
            shareBuyback:           buyback.current
        )
    }

    /// financials 組立の本表水準値が statement 正本のみから取れることを smoke 11 社で回帰する
    ///（タスク #5 / #5b-1。旧 Extractor フォールバックなし）。
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

            /// 期待値があるフィールドは statement が必ず返し一致すること（#5b-1）。
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
            assertRequired(
                "current_assets", expected: dbl(bs["current_assets"]),
                actual: statement.currentAssets)
            assertRequired(
                "non_current_assets", expected: dbl(bs["non_current_assets"]),
                actual: statement.nonCurrentAssets)
            assertRequired(
                "current_liabilities", expected: dbl(bs["current_liabilities"]),
                actual: statement.currentLiabilities)
            assertRequired(
                "non_current_liabilities", expected: dbl(bs["non_current_liabilities"]),
                actual: statement.nonCurrentLiabilities)
            assertRequired(
                "ppe_total",
                expected: dbl((expected["tangible_fixed_assets"] as? [String: Any])?["total"]),
                actual: statement.ppeTotal)
            assertRequired(
                "cash_eq", expected: dbl((expected["cash_eq"] as? [String: Any])?["current"]),
                actual: statement.cashEquivalents)
            assertRequired(
                "dividend_paid_cf",
                expected: dbl((expected["dividend_paid_cf"] as? [String: Any])?["current"]),
                actual: statement.dividendPaidCF)
            assertRequired(
                "accounts_receivable",
                expected: dbl((expected["accounts_receivable"] as? [String: Any])?["current"]),
                actual: statement.accountsReceivable)
            assertRequired(
                "inventory",
                expected: dbl((expected["inventory"] as? [String: Any])?["current"]),
                actual: statement.inventory)
            assertRequired(
                "accounts_payable",
                expected: dbl((expected["accounts_payable"] as? [String: Any])?["current"]),
                actual: statement.accountsPayable)
            assertRequired(
                "gross_profit",
                expected: dbl((expected["gross_profit"] as? [String: Any])?["gross_profit"]),
                actual: statement.grossProfit)
            assertRequired(
                "sga", expected: dbl((expected["sga"] as? [String: Any])?["current"]),
                actual: statement.sga)
            assertRequired(
                "pretax_income",
                expected: dbl((expected["tax_expense"] as? [String: Any])?["pretax_income"]),
                actual: statement.pretaxIncome)
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

    /// Summary（financials 組立）の未移行フィールドが、statement 正本マスク / 0101010
    /// `SummaryOfBusinessResults` タグだけで smoke 期待値に届くかを測る。
    /// 既存の done フィールド（本表パススルー・notes EPS/株式）は対象外。
    @Test func testSummaryPathChangeFeasibility() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            print("SKIP   smoke/smoke_expected が見つかりません")
            return
        }
        await SmokeCacheSupport.ensureCached(Self.docIDs.values)

        struct FieldStat {
            var expected = 0
            var statementOK = 0
            var summaryOK = 0
            var currentOK = 0
            var statementNil = 0
            var summaryNil = 0
        }
        var stats: [String: FieldStat] = [:]
        var companyLines: [String] = []
        var checked = 0

        let remaining: [(field: String, expectedKey: ( [String: Any] ) -> Double?)] = [
            ("gross_profit", { dbl(($0["gross_profit"] as? [String: Any])?["gross_profit"]) }),
            ("sga", { dbl(($0["sga"] as? [String: Any])?["current"]) }),
            ("cfo", { dbl(($0["cash_flow"] as? [String: Any])?["cfo"]) }),
            ("cfi", { dbl(($0["cash_flow"] as? [String: Any])?["cfi"]) }),
            ("ibd", { dbl(($0["interest_bearing_debt"] as? [String: Any])?["total"]) }),
            ("pretax_income", { dbl(($0["tax_expense"] as? [String: Any])?["pretax_income"]) }),
            ("income_tax", { dbl(($0["tax_expense"] as? [String: Any])?["income_tax"]) }),
            ("rd", { dbl(($0["research_development"] as? [String: Any])?["current"]) }),
            ("employees", { dbl(($0["employees"] as? [String: Any])?["current"]) }),
            ("interest_expense", { dbl(($0["interest_expense"] as? [String: Any])?["current"]) }),
            ("cf_treasury_stock", { dbl(($0["cf_treasury_stock"] as? [String: Any])?["current"]) }),
            ("dividend_ss", { dbl(($0["dividend_ss"] as? [String: Any])?["current"]) }),
        ]

        for (fixtureID, docID) in Self.docIDs.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            let fixturePath = fixtureDir.appendingPathComponent("\(fixtureID).json")
            guard FileManager.default.fileExists(atPath: xbrlDir.path),
                  FileManager.default.fileExists(atPath: fixturePath.path),
                  let expected = try? loadFixture(fixturePath),
                  !isAllNull(expected)
            else { continue }

            let current = extractFromXBRL(xbrlDir: xbrlDir)
            let statementVals = statementRemainingValues(xbrlDir: xbrlDir)
            let summaryVals = summaryTagRemainingValues(xbrlDir: xbrlDir)
            checked += 1

            var cells: [String] = [fixtureID]
            for spec in remaining {
                let exp = spec.expectedKey(expected)
                let st: Double? = statementVals[spec.field] ?? nil
                let sm: Double? = summaryVals[spec.field] ?? nil
                let cu = currentRemainingValue(current, field: spec.field)
                var stat = stats[spec.field] ?? FieldStat()
                if let exp {
                    stat.expected += 1
                    if closeEnough(exp, st) { stat.statementOK += 1 }
                    else if st == nil { stat.statementNil += 1 }
                    if closeEnough(exp, sm) { stat.summaryOK += 1 }
                    else if sm == nil { stat.summaryNil += 1 }
                    if closeEnough(exp, cu) { stat.currentOK += 1 }
                }
                stats[spec.field] = stat
                cells.append(
                    "\(statusMark(exp: exp, act: st))/\(statusMark(exp: exp, act: sm))/\(statusMark(exp: exp, act: cu))"
                )
            }
            companyLines.append(cells.joined(separator: " | "))
        }

        guard checked > 0 else {
            print("SKIP   summary 経路変更可行性: XBRL キャッシュなし")
            return
        }

        print("summary path feasibility (\(checked) companies)")
        print("cell = statement / SummaryOfBusinessResults / current extractor")
        print(
            "fixture | "
                + remaining.map(\.field).joined(separator: " | "))
        for line in companyLines { print(line) }

        var switchable: [String] = []
        var partial: [String] = []
        var blocked: [String] = []
        var summaryEnough: [String] = []
        for spec in remaining {
            let s = stats[spec.field] ?? FieldStat()
            let line =
                "\(spec.field): expected=\(s.expected) statement=\(s.statementOK) (nil=\(s.statementNil)) summaryTags=\(s.summaryOK) (nil=\(s.summaryNil)) current=\(s.currentOK)"
            print(line)
            if s.expected > 0 && s.statementOK == s.expected { switchable.append(spec.field) }
            else if s.statementOK > 0 { partial.append("\(spec.field)(\(s.statementOK)/\(s.expected))") }
            else { blocked.append(spec.field) }
            if s.expected > 0 && s.summaryOK == s.expected { summaryEnough.append(spec.field) }
        }
        print("statement-switchable-now: \(switchable.joined(separator: ", "))")
        print("statement-partial: \(partial.joined(separator: ", "))")
        print("statement-blocked: \(blocked.joined(separator: ", "))")
        print("summary-tags-enough: \(summaryEnough.joined(separator: ", "))")

        var mainStats: [String: FieldStat] = [:]
        let mainFields: [(field: String, expectedKey: ([String: Any]) -> Double?)] = [
            ("sales", { dbl(($0["income_statement"] as? [String: Any])?["sales"]) }),
            ("operating_profit", { dbl(($0["income_statement"] as? [String: Any])?["operating_profit"]) }),
            ("net_profit", { dbl(($0["income_statement"] as? [String: Any])?["net_profit"]) }),
            ("total_assets", { dbl(($0["balance_sheet"] as? [String: Any])?["total_assets"]) }),
            ("current_assets", { dbl(($0["balance_sheet"] as? [String: Any])?["current_assets"]) }),
            ("non_current_assets", { dbl(($0["balance_sheet"] as? [String: Any])?["non_current_assets"]) }),
            ("current_liabilities", { dbl(($0["balance_sheet"] as? [String: Any])?["current_liabilities"]) }),
            ("non_current_liabilities", { dbl(($0["balance_sheet"] as? [String: Any])?["non_current_liabilities"]) }),
            ("net_assets", { dbl(($0["balance_sheet"] as? [String: Any])?["net_assets"]) }),
            ("ppe_total", { dbl(($0["tangible_fixed_assets"] as? [String: Any])?["total"]) }),
            ("cash_eq", { dbl(($0["cash_eq"] as? [String: Any])?["current"]) }),
        ]
        print("main-table vs SummaryOfBusinessResults tags")
        for (fixtureID, docID) in Self.docIDs.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            let fixturePath = fixtureDir.appendingPathComponent("\(fixtureID).json")
            guard FileManager.default.fileExists(atPath: xbrlDir.path),
                  let expected = try? loadFixture(fixturePath),
                  !isAllNull(expected)
            else { continue }
            let summaryMain = summaryTagMainTableValues(xbrlDir: xbrlDir)
            let statementMain = StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)
            for spec in mainFields {
                let exp = spec.expectedKey(expected)
                let sm = summaryMain[spec.field] ?? nil
                let st: Double? = {
                    switch spec.field {
                    case "sales": return statementMain?.sales
                    case "operating_profit": return statementMain?.operatingProfit
                    case "net_profit": return statementMain?.netProfit
                    case "total_assets": return statementMain?.totalAssets
                    case "current_assets": return statementMain?.currentAssets
                    case "non_current_assets": return statementMain?.nonCurrentAssets
                    case "current_liabilities": return statementMain?.currentLiabilities
                    case "non_current_liabilities": return statementMain?.nonCurrentLiabilities
                    case "net_assets": return statementMain?.netAssets
                    case "ppe_total": return statementMain?.ppeTotal
                    case "cash_eq": return statementMain?.cashEquivalents
                    default: return nil
                    }
                }()
                var stat = mainStats[spec.field] ?? FieldStat()
                if let exp {
                    stat.expected += 1
                    if closeEnough(exp, st) { stat.statementOK += 1 }
                    else if st == nil { stat.statementNil += 1 }
                    if closeEnough(exp, sm) { stat.summaryOK += 1 }
                    else if sm == nil { stat.summaryNil += 1 }
                }
                mainStats[spec.field] = stat
            }
        }
        var summaryMainEnough: [String] = []
        var summaryMainBlocked: [String] = []
        for spec in mainFields {
            let s = mainStats[spec.field] ?? FieldStat()
            print(
                "\(spec.field): expected=\(s.expected) statement=\(s.statementOK) (nil=\(s.statementNil)) summaryTags=\(s.summaryOK) (nil=\(s.summaryNil))"
            )
            if s.expected > 0 && s.summaryOK == s.expected { summaryMainEnough.append(spec.field) }
            if s.expected > 0 && s.summaryOK == 0 { summaryMainBlocked.append(spec.field) }
        }
        print("summary-tags-main-enough: \(summaryMainEnough.joined(separator: ", "))")
        print("summary-tags-main-blocked: \(summaryMainBlocked.joined(separator: ", "))")

        // 現行 Extractor が期待値を満たすことは床。statement 全面置換はまだ要求しない。
        for spec in remaining {
            let s = stats[spec.field] ?? FieldStat()
            #expect(
                s.expected == 0 || s.currentOK == s.expected,
                "\(spec.field): current extractor \(s.currentOK)/\(s.expected)")
        }
        // smoke 11 社で statement 行だけで期待値に届く未移行フィールド。経路切替の床。
        for field in ["gross_profit", "sga", "pretax_income"] {
            let s = stats[field] ?? FieldStat()
            #expect(
                s.expected > 0 && s.statementOK == s.expected,
                "\(field): statement path \(s.statementOK)/\(s.expected)")
        }
    }

    /// 組立ルール（statement で計算できればそれ、できなければ notes）を既存 smoke IBD 期待値と突合する。
    /// A: statement が非 nil なら採用（リース未加算でも採用）。
    /// B: statement が現行 Extractor 合計と一致するときだけ採用（BS だけで足りる場合）。それ以外は notes。
    /// C: B と同じだが銀行 `bank_components`（預金込み）は statement 不足とみなし notes へ。
    @Test func testSummaryIbdAssemblyVsSmokeExpected() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            print("SKIP   smoke/smoke_expected が見つかりません")
            return
        }
        await SmokeCacheSupport.ensureCached(Self.docIDs.values)

        var checked = 0
        var aOK = 0
        var bOK = 0
        var cOK = 0
        var notesOK = 0
        var statementOK = 0

        print("ibd assembly vs smoke expected")
        print(
            "fixture | std | smoke | extractor | statement | notes | notes_via | A | B | C"
        )
        for (fixtureID, docID) in Self.docIDs.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            let fixturePath = fixtureDir.appendingPathComponent("\(fixtureID).json")
            guard FileManager.default.fileExists(atPath: xbrlDir.path),
                  FileManager.default.fileExists(atPath: fixturePath.path),
                  let expected = try? loadFixture(fixturePath),
                  !isAllNull(expected)
            else { continue }

            let smoke = dbl((expected["interest_bearing_debt"] as? [String: Any])?["total"])
            let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
            let std = detectAccountingStandard(allTags)
            var instantFS = fieldSetFromInstant(allTags)
            if std == "US-GAAP" {
                for (tag, fv) in USGAAPHtml.parseBSFields(in: xbrlDir) { instantFS[tag] = fv }
            }
            let extractor = IBDExtractor.extract(
                fieldSet: instantFS, accountingStandard: std, xbrlDir: xbrlDir)
            let statement = statementRemainingValues(xbrlDir: xbrlDir)["ibd"] ?? nil
            let notes = notesIbdTotal(xbrlDir: xbrlDir)

            let ruleA = statement ?? notes.value
            let statementComplete = closeEnoughOptional(statement, extractor.total)
            let ruleB = statementComplete ? statement : notes.value
            let bank = extractor.method.hasPrefix("bank_components")
            let ruleC = (statementComplete && !bank) ? statement : notes.value

            checked += 1
            if closeEnoughOptional(smoke, statement) { statementOK += 1 }
            if closeEnoughOptional(smoke, notes.value) { notesOK += 1 }
            if closeEnoughOptional(smoke, ruleA) { aOK += 1 }
            if closeEnoughOptional(smoke, ruleB) { bOK += 1 }
            if closeEnoughOptional(smoke, ruleC) { cOK += 1 }

            print(
                "\(fixtureID) | \(std) | \(yen(smoke)) | \(extractor.method) | \(yen(statement)) | \(yen(notes.value)) | \(notes.detail) | \(statusMark(exp: smoke, act: ruleA)) | \(statusMark(exp: smoke, act: ruleB)) | \(statusMark(exp: smoke, act: ruleC))"
            )
        }

        guard checked > 0 else {
            print("SKIP   ibd assembly vs smoke: XBRL キャッシュなし")
            return
        }
        print("checked=\(checked)")
        print("statement-vs-smoke: \(statementOK)/\(checked)")
        print("notes-vs-smoke: \(notesOK)/\(checked)")
        print("ruleA statement-if-non-nil: \(aOK)/\(checked)")
        print("ruleB statement-if-complete-else-notes: \(bOK)/\(checked)")
        print("ruleC B-but-banks-to-notes: \(cOK)/\(checked)")
        #expect(checked == Self.docIDs.count)
    }

    /// statement の有利子負債項目 ＋ statement に無い notes 項目（合計行は使わない）が
    /// 既存 smoke IBD と揃うか。
    @Test func testIbdItemTagsComposeVsSmoke() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = SmokeCacheSupport.cacheDir
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            print("SKIP   smoke/smoke_expected が見つかりません")
            return
        }
        await SmokeCacheSupport.ensureCached(Self.docIDs.values)

        var checked = 0
        var match = 0
        print("ibd item-tag compose vs smoke")
        print("fixture | std | smoke | composed | extras | mark")

        for (fixtureID, docID) in Self.docIDs.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            let fixturePath = fixtureDir.appendingPathComponent("\(fixtureID).json")
            guard FileManager.default.fileExists(atPath: xbrlDir.path),
                  FileManager.default.fileExists(atPath: fixturePath.path),
                  let expected = try? loadFixture(fixturePath),
                  !isAllNull(expected)
            else { continue }

            let smoke = dbl((expected["interest_bearing_debt"] as? [String: Any])?["total"])
            let composed = composeIbdFromItemTags(xbrlDir: xbrlDir)
            checked += 1
            if closeEnoughOptional(smoke, composed.total) { match += 1 }
            print(
                "\(fixtureID) | \(composed.std) | \(yen(smoke)) | \(yen(composed.total)) | \(composed.extras) | \(statusMark(exp: smoke, act: composed.total))"
            )
            print("  parts: \(composed.parts)")
        }
        print("composed-vs-smoke: \(match)/\(checked)")
        guard checked > 0 else {
            print("SKIP   ibd item-tag compose vs smoke: XBRL キャッシュなし")
            return
        }
        #expect(checked == Self.docIDs.count)
        #expect(match == checked, "item-tag IBD compose \(match)/\(checked) vs smoke")
    }

    /// 未配線フィールドを statement → notes → breakdown で組み、smoke 期待値と突合する。
    /// employees / rd は breakdown 分母のみ（statement PL は使わない）。
    /// IBD は `testIbdItemTagsComposeVsSmoke`。IndividualAnalyzer の差し替えはしない。
    @Test func testRemainingFieldsComposeVsSmoke() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureDir = projectRoot.appendingPathComponent("smoke/smoke_expected")
        let xbrlBase = SmokeCacheSupport.cacheDir
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            print("SKIP   smoke/smoke_expected が見つかりません")
            return
        }
        await SmokeCacheSupport.ensureCached(Self.docIDs.values)

        let fields: [(name: String, expectedKey: ([String: Any]) -> Double?)] = [
            ("gross_profit", { dbl(($0["gross_profit"] as? [String: Any])?["gross_profit"]) }),
            ("sga", { dbl(($0["sga"] as? [String: Any])?["current"]) }),
            ("cfo", { dbl(($0["cash_flow"] as? [String: Any])?["cfo"]) }),
            ("cfi", { dbl(($0["cash_flow"] as? [String: Any])?["cfi"]) }),
            ("pretax_income", { dbl(($0["tax_expense"] as? [String: Any])?["pretax_income"]) }),
            ("income_tax", { dbl(($0["tax_expense"] as? [String: Any])?["income_tax"]) }),
            ("rd", { dbl(($0["research_development"] as? [String: Any])?["current"]) }),
            ("employees", { dbl(($0["employees"] as? [String: Any])?["current"]) }),
            ("interest_expense", { dbl(($0["interest_expense"] as? [String: Any])?["current"]) }),
            ("cf_treasury_stock", { dbl(($0["cf_treasury_stock"] as? [String: Any])?["current"]) }),
            ("dividend_ss", { dbl(($0["dividend_ss"] as? [String: Any])?["current"]) }),
            ("buyback", { dbl(($0["share_buyback"] as? [String: Any])?["current"]) }),
        ]

        struct FieldStat {
            var expected = 0
            var statementOK = 0
            var composedOK = 0
            var currentOK = 0
        }
        var stats: [String: FieldStat] = [:]
        var checked = 0

        print("remaining compose vs smoke (statement → notes → breakdown; employees/rd は breakdown のみ)")
        print("cell = statement / composed / current")
        print("fixture | " + fields.map(\.name).joined(separator: " | "))

        for (fixtureID, docID) in Self.docIDs.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            let fixturePath = fixtureDir.appendingPathComponent("\(fixtureID).json")
            guard FileManager.default.fileExists(atPath: xbrlDir.path),
                  FileManager.default.fileExists(atPath: fixturePath.path),
                  let expected = try? loadFixture(fixturePath),
                  !isAllNull(expected),
                  let statement = StatementFinancialsResolver.resolve(xbrlDir: xbrlDir)
            else { continue }

            let notes = notesRemainingFills(xbrlDir: xbrlDir)
            let breakdown = breakdownRemainingFills(xbrlDir: xbrlDir)
            let current = extractFromXBRL(xbrlDir: xbrlDir)
            checked += 1

            var cells: [String] = [fixtureID]
            for spec in fields {
                let exp = spec.expectedKey(expected)
                let st = statementRemainingField(statement, spec.name)
                let breakdownOnly = spec.name == "employees" || spec.name == "rd"
                let composed = breakdownOnly
                    ? breakdown[spec.name]
                    : (st ?? notes[spec.name] ?? breakdown[spec.name])
                let cu = currentRemainingValue(current, field: spec.name)
                var stat = stats[spec.name] ?? FieldStat()
                if let exp {
                    stat.expected += 1
                    if closeEnough(exp, st) { stat.statementOK += 1 }
                    if closeEnough(exp, composed) { stat.composedOK += 1 }
                    if closeEnough(exp, cu) { stat.currentOK += 1 }
                }
                stats[spec.name] = stat
                cells.append(
                    "\(statusMark(exp: exp, act: st))/\(statusMark(exp: exp, act: composed))/\(statusMark(exp: exp, act: cu))"
                )
            }
            print(cells.joined(separator: " | "))
        }

        guard checked > 0 else {
            print("SKIP   remaining compose vs smoke: XBRL キャッシュなし")
            return
        }

        var switchable: [String] = []
        var composedOK: [String] = []
        var partial: [String] = []
        for spec in fields {
            let s = stats[spec.name] ?? FieldStat()
            print(
                "\(spec.name): expected=\(s.expected) statement=\(s.statementOK) composed=\(s.composedOK) current=\(s.currentOK)"
            )
            if s.expected > 0 && s.statementOK == s.expected { switchable.append(spec.name) }
            else if s.expected > 0 && s.composedOK == s.expected { composedOK.append(spec.name) }
            else if s.composedOK > 0 { partial.append("\(spec.name)(\(s.composedOK)/\(s.expected))") }
        }
        print("statement-switchable-now: \(switchable.joined(separator: ", "))")
        print("compose-complete: \(composedOK.joined(separator: ", "))")
        print("compose-partial: \(partial.joined(separator: ", "))")

        #expect(checked == Self.docIDs.count)
        for spec in fields {
            let s = stats[spec.name] ?? FieldStat()
            #expect(
                s.expected == 0 || s.currentOK == s.expected,
                "\(spec.name): current extractor \(s.currentOK)/\(s.expected)")
        }
        for field in ["gross_profit", "sga", "pretax_income", "cfo", "cfi", "income_tax", "dividend_ss", "cf_treasury_stock", "buyback"] {
            let s = stats[field] ?? FieldStat()
            #expect(
                s.expected > 0 && s.statementOK == s.expected,
                "\(field): statement path \(s.statementOK)/\(s.expected)")
        }
        for field in ["gross_profit", "sga", "pretax_income", "rd", "employees", "cfo", "cfi", "income_tax", "dividend_ss", "interest_expense", "cf_treasury_stock", "buyback"] {
            let s = stats[field] ?? FieldStat()
            #expect(
                s.expected > 0 && s.composedOK == s.expected,
                "\(field): composed \(s.composedOK)/\(s.expected)")
        }
    }

    private func ibdFamily(_ label: String) -> String {
        if label.contains("リース") { return "lease" }
        if label.contains("コマーシャル") { return "cp" }
        if label.contains("預金") { return "deposits" }
        let cl = label.contains("1年") || label.contains("１年") || label.contains("年内")
        if label.contains("社債") { return cl ? "bonds_cl" : "bonds" }
        if label.contains("借入") || label.contains("借用") {
            if label.contains("短期") { return "st" }
            if cl { return "lt_cl" }
            return "borrowings"
        }
        return label
    }

    private func composeIbdFromItemTags(xbrlDir: URL) -> (
        std: String, total: Double?, parts: String, extras: String
    ) {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        var instantFS: FieldSet
        if std == "US-GAAP" {
            instantFS = [:]
            for (tag, fv) in USGAAPHtml.parseBSFields(in: xbrlDir) { instantFS[tag] = fv }
        } else if case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir, docID: nil, statementTypes: [.balanceSheet]
        ) {
            let statementTags = Set(year.balanceSheet.map(\.tag))
            instantFS = fieldSetFromInstant(allTags.filter { statementTags.contains($0.key) })
        } else {
            instantFS = fieldSetFromInstant(allTags)
        }

        let statementIBD = IBDExtractor.extract(
            fieldSet: instantFS, accountingStandard: std, xbrlDir: nil)
        var families = Set(statementIBD.components.compactMap { c -> String? in
            guard c.current != nil else { return nil }
            return ibdFamily(c.label)
        })
        var total = statementIBD.components.reduce(0.0) { $0 + ($1.current ?? 0) }
        var hasAny = statementIBD.components.contains { $0.current != nil }
        var parts: [String] = statementIBD.components.compactMap { c in
            guard let v = c.current else { return nil }
            return "stmt:\(c.label)=\(yen(v))"
        }
        var extras: [String] = []

        if !families.contains("lease") {
            var leaseBook: Double?
            if case .resolved = StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir) {
                leaseBook = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir).current
            }
            if leaseBook == nil, case .resolved(let payload, _, _) =
                StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: xbrlDir)
            {
                let leaseRows = (payload.borrowingsComponents ?? []).filter {
                    !$0.isTotal && ibdFamily($0.label) == "lease"
                }
                let sum = leaseRows.compactMap(\.currentBalance).reduce(0, +)
                if !leaseRows.isEmpty { leaseBook = sum }
            }
            if let leaseBook {
                total += leaseBook
                hasAny = true
                families.insert("lease")
                parts.append("notes:lease=\(yen(leaseBook))")
            }
        }

        if !hasAny, case .resolved(let payload, _, _) =
            StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: xbrlDir)
        {
            for row in payload.borrowingsComponents ?? [] {
                guard !row.isTotal, let value = row.currentBalance else { continue }
                total += value
                hasAny = true
                extras.append("\(row.label)=\(yen(value))")
                parts.append("notes:\(row.label)=\(yen(value))")
            }
        }

        return (
            std: std,
            total: hasAny ? total : nil,
            parts: parts.joined(separator: ", "),
            extras: extras.isEmpty ? "-" : extras.joined(separator: ", ")
        )
    }

    /// 味の素 statement IBD（4,554億）の内訳と、BS / notes / リースの抽出項目を全部出す。
    @Test func testAjinomotoStatementIbdComponentsDump() async throws {
        let docID = "S100VXJA"
        await SmokeCacheSupport.ensureCached([docID])
        let xbrlDir = SmokeCacheSupport.cacheDir.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
            print("SKIP   Ajinomoto XBRL cache missing")
            return
        }

        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir, docID: docID,
            statementTypes: [.balanceSheet]
        ) else {
            Issue.record("statement resolve failed")
            return
        }
        let statementTags = Set(year.balanceSheet.map(\.tag))
        let masked = allTags.filter { statementTags.contains($0.key) }
        let instantFS = fieldSetFromInstant(masked)
        let fullFS = fieldSetFromInstant(allTags)

        let statementIBD = IBDExtractor.extract(
            fieldSet: instantFS, accountingStandard: "IFRS", xbrlDir: nil)
        let fullIBD = IBDExtractor.extract(
            fieldSet: fullFS, accountingStandard: "IFRS", xbrlDir: xbrlDir)

        let direct = resolveItem(instantFS, tags: Xbrl.ibdDirectTags)
        let ifrsAgg = resolveAggregate(
            instantFS, componentTagLists: [Xbrl.ibdIFRSCLTags, Xbrl.ibdIFRSNCLTags])
        let comp = resolveAggregate(
            instantFS, componentTagLists: Xbrl.ibdCurrentComponents + Xbrl.ibdNonCurrentComponents)

        func yenLine(_ v: Double?) -> String {
            guard let v else { return "nil" }
            return "\(fmt(v)) (\(yen(v)))"
        }

        print("=== 味の素 S100VXJA statement IBD ===")
        print("statement IBDExtractor total=\(yenLine(statementIBD.total)) method=\(statementIBD.method)")
        print("full IBDExtractor total=\(yenLine(fullIBD.total)) method=\(fullIBD.method)")
        print("resolve path: direct.tag=\(direct.tag ?? "nil") ifrsAgg.tag=\(ifrsAgg.tag ?? "nil") comp.tag=\(comp.tag ?? "nil")")
        print("ifrsAgg current=\(yenLine(ifrsAgg.current))")
        print("component-stack current=\(yenLine(comp.current))")

        print("--- IBDExtractor statement components ---")
        for c in statementIBD.components {
            print("  \(c.label): current=\(yenLine(c.current)) prior=\(yenLine(c.prior))")
        }
        print("--- IBDExtractor full components ---")
        for c in fullIBD.components {
            print("  \(c.label): current=\(yenLine(c.current)) prior=\(yenLine(c.prior))")
        }

        var candidateTags: [String] = []
        candidateTags.append(contentsOf: Xbrl.ibdDirectTags)
        candidateTags.append(contentsOf: Xbrl.ibdIFRSCLTags)
        candidateTags.append(contentsOf: Xbrl.ibdIFRSNCLTags)
        candidateTags.append(contentsOf: Xbrl.ibdCurrentComponents.flatMap { $0 })
        candidateTags.append(contentsOf: Xbrl.ibdNonCurrentComponents.flatMap { $0 })
        candidateTags.append(contentsOf: Xbrl.leaseLiabilitiesBSTags)
        candidateTags.append(contentsOf: [
            "BondsAndBorrowingsLiabilitiesIFRS",
            "FinancialLiabilitiesIFRS",
            "OtherFinancialLiabilitiesIFRS",
            "OtherFinancialLiabilitiesCLIFRS",
            "OtherFinancialLiabilitiesNCLIFRS",
        ])
        print("--- IBD/金融負債 candidate tags on statement FieldSet ---")
        var seen = Set<String>()
        for tag in candidateTags {
            guard !seen.contains(tag) else { continue }
            seen.insert(tag)
            let onStatement = statementTags.contains(tag)
            let fv = instantFS[tag]
            let full = fullFS[tag]
            if fv?.current != nil || fv?.prior != nil || full?.current != nil || onStatement {
                print(
                    "  \(tag): statement=\(onStatement) stmtCurrent=\(yenLine(fv?.current)) stmtPrior=\(yenLine(fv?.prior)) fullCurrent=\(yenLine(full?.current))"
                )
            }
        }

        let keywords = ["借入", "社債", "リース", "コマーシャル", "有利子", "金融負債", "債券", "CP"]
        print("--- statement BS lines matching debt/lease/financial-liability labels ---")
        for item in year.balanceSheet.sorted(by: { ($0.order ?? 0) < ($1.order ?? 0) }) {
            let label = item.label ?? ""
            let tag = item.tag
            let keywordHit = keywords.contains { label.contains($0) || tag.contains($0) }
            let tagHit =
                tag.contains("Borrow") || tag.contains("Bond") || tag.contains("Lease")
                || tag.contains("FinancialLiab") || tag.contains("CommercialPaper")
                || tag.contains("InterestBearing")
            guard keywordHit || tagHit else { continue }
            var extra = ""
            if item.isTotal {
                extra += " is_total"
                if let comps = item.components {
                    extra += " children=[" + comps.map { "\($0.tag) w=\($0.weight)" }.joined(separator: ", ") + "]"
                }
            }
            print(
                "  order=\(item.order.map(String.init) ?? "-") section=\(item.section?.rawValue ?? "-") \(item.tag) |\(label)| \(yenLine(item.value))\(extra)"
            )
        }

        print("--- notes borrowings_schedule ---")
        switch StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: xbrlDir) {
        case .resolved(let payload, _, _):
            for row in payload.borrowingsComponents ?? [] {
                print(
                    "  \(row.isTotal ? "TOTAL " : "")\(row.label): current=\(yenLine(row.currentBalance)) prior=\(yenLine(row.priorBalance)) rate=\(row.averageInterestRatePercent.map { String($0) } ?? "nil")"
                )
            }
        case .notApplicable(let reason):
            print("  notApplicable \(reason)")
        case .failed:
            print("  failed")
        }

        print("--- notes lease_liabilities ---")
        switch StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir) {
        case .resolved(let payload, _, _):
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir)
            print("  book=\(yenLine(lease.current))")
            for item in payload.items ?? [] {
                print("  \(item.label ?? "?"): \(yenLine(item.value)) tag=\(item.tag)")
            }
        case .notApplicable(let reason):
            print("  notApplicable \(reason)")
        case .failed:
            print("  failed")
        }

        let statementTotal = try #require(statementIBD.total)
        #expect(abs(statementTotal - 455_353_000_000) / 455_353_000_000 < 1e-4)
        let leaseBook = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir).current
        if let leaseBook, let full = fullIBD.total {
            #expect(abs((statementTotal + leaseBook) - full) < 1)
        }
    }

    /// notes の IBD: 借入金等明細表合計。明細にリース行が無く `lease_liabilities` が resolved なら帳簿価額を足す。
    private func notesIbdTotal(xbrlDir: URL) -> (value: Double?, detail: String) {
        var borrowings: Double?
        switch StatementNotesResolver.resolveBorrowingsSchedule(xbrlDir: xbrlDir) {
        case .resolved(let payload, _, _):
            borrowings = payload.borrowingsComponents?.first(where: \.isTotal)?.currentBalance
        default:
            break
        }
        let hasLeaseRow = BorrowingsSchedule.hasLeaseDebtRowLabel(xbrlDir: xbrlDir)
        var leaseBook: Double?
        var leaseStatus = "n/a"
        switch StatementNotesResolver.resolveLeaseLiabilities(xbrlDir: xbrlDir) {
        case .resolved:
            leaseStatus = "resolved"
            leaseBook = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir).current
        case .notApplicable(let reason):
            leaseStatus = reason
        case .failed:
            leaseStatus = "failed"
        }

        if hasLeaseRow, let borrowings {
            return (borrowings, "borrowings+lease-rows; lease=\(leaseStatus)")
        }
        if let borrowings, let leaseBook {
            return (borrowings + leaseBook, "borrowings+lease_note; lease=\(leaseStatus)")
        }
        if let borrowings {
            return (borrowings, "borrowings; lease=\(leaseStatus)")
        }
        if let leaseBook {
            return (leaseBook, "lease_note; lease=\(leaseStatus)")
        }
        return (nil, "none; lease=\(leaseStatus)")
    }

    private func closeEnoughOptional(_ expected: Double?, _ actual: Double?) -> Bool {
        guard let expected else { return actual == nil }
        return closeEnough(expected, actual)
    }

    private func yen(_ v: Double?) -> String {
        guard let v else { return "nil" }
        if abs(v) >= 1e12 { return String(format: "%.2f兆", v / 1e12) }
        if abs(v) >= 1e8 { return String(format: "%.1f億", v / 1e8) }
        return fmt(v)
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

        let buyback = expected["share_buyback"] as? [String: Any] ?? [:]
        check("shareBuyback", exp: dbl(buyback["current"]), act: actual.shareBuyback)

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

    private func closeEnough(_ expected: Double, _ actual: Double?) -> Bool {
        guard let actual else { return false }
        let tol = max(abs(expected) * Self.relTol, 1.0)
        return abs(expected - actual) <= tol
    }

    private func statusMark(exp: Double?, act: Double?) -> String {
        guard exp != nil else { return "-" }
        if closeEnough(exp!, act) { return "OK" }
        return act == nil ? "nil" : "DIFF"
    }

    private func currentRemainingValue(_ actual: Extracted, field: String) -> Double? {
        switch field {
        case "gross_profit": return actual.grossProfit
        case "sga": return actual.sga
        case "cfo": return actual.cfo
        case "cfi": return actual.cfi
        case "ibd": return actual.ibdTotal
        case "pretax_income": return actual.pretaxIncome
        case "income_tax": return actual.incomeTax
        case "rd": return actual.rd
        case "employees": return actual.employees
        case "interest_expense": return actual.interestExpense
        case "cf_treasury_stock": return actual.cfTreasuryStock
        case "dividend_ss": return actual.dividendSS
        case "buyback": return actual.shareBuyback
        default: return nil
        }
    }

    private func statementRemainingField(_ statement: StatementFinancialsValues, _ field: String) -> Double? {
        switch field {
        case "gross_profit": return statement.grossProfit
        case "sga": return statement.sga
        case "cfo": return statement.cfo
        case "cfi": return statement.cfi
        case "pretax_income": return statement.pretaxIncome
        case "income_tax": return statement.incomeTax
        case "interest_expense": return statement.interestExpense
        case "cf_treasury_stock": return statement.cfTreasuryStock
        case "dividend_ss": return statement.dividendSS
        case "buyback": return statement.buyback
        default: return nil
        }
    }

    /// notes から足せる未配線フィールド。statement で取れた値は組立側で優先する。
    private func notesRemainingFills(xbrlDir: URL) -> [String: Double] {
        var out: [String: Double] = [:]
        if case .resolved(let payload, _, _) = StatementNotesResolver.resolveDividends(xbrlDir: xbrlDir) {
            let sum = (payload.dividendEvents ?? []).compactMap(\.totalAmount).reduce(0, +)
            if sum != 0 { out["dividend_ss"] = sum }
        }
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        if std == "IFRS" {
            // 注記の支払利息タグ（InterestExpensesIFRS 等）と TextBlock。空 FieldSet だと
            // 数値タグを逃して文章パターンだけになり、smoke 期待値と不一致になる。
            let ie = InterestExpenseExtractor.extract(
                fieldSet: fieldSetFromDuration(allTags), accountingStandard: std, xbrlDir: xbrlDir)
            if let v = ie.current { out["interest_expense"] = v }
        }
        return out
    }

    /// breakdown 正本の分母（employees / rd）。PL 行は使わない。
    private func breakdownRemainingFills(xbrlDir: URL) -> [String: Double] {
        var out: [String: Double] = [:]
        if let v = BreakdownFinancialsResolver.financialsCanonicalEmployees(xbrlDir: xbrlDir) {
            out["employees"] = v
        }
        if let v = BreakdownFinancialsResolver.financialsCanonicalRd(xbrlDir: xbrlDir) {
            out["rd"] = v
        }
        return out
    }

    private func firstByLabel(_ items: [StatementLineItem], contains: String, excluding: [String] = []) -> Double? {
        for item in items {
            let label = item.label ?? ""
            guard label.contains(contains) else { continue }
            if excluding.contains(where: { label.contains($0) }) { continue }
            return item.value
        }
        return nil
    }

    /// statement 行のタグだけを許可した FieldSet で未移行 Extractor を回す。US-GAAP は
    /// 合成タグのためラベルから直接拾う。HTML/TextBlock フォールバックは付けない。
    private func statementRemainingValues(xbrlDir: URL) -> [String: Double?] {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: xbrlDir, docID: nil,
            statementTypes: [.balanceSheet, .incomeStatement, .cashFlow, .changesInEquity]
        ) else { return [:] }

        if std == "US-GAAP" {
            return [
                "gross_profit": firstByLabel(year.incomeStatement, contains: "売上総利益"),
                "sga": firstByLabel(year.incomeStatement, contains: "販売費及び一般管理費"),
                "cfo": firstByLabel(
                    year.cashFlow, contains: "営業活動によるキャッシュ・フロー",
                    excluding: ["期首", "期末", "明細"]),
                "cfi": firstByLabel(
                    year.cashFlow, contains: "投資活動によるキャッシュ・フロー",
                    excluding: ["期首", "期末", "明細"]),
                "ibd": nil,
                "pretax_income": firstByLabel(year.incomeStatement, contains: "税引前")
                    ?? firstByLabel(year.incomeStatement, contains: "税金等調整前"),
                "income_tax": firstByLabel(year.incomeStatement, contains: "法人税等")
                    ?? firstByLabel(year.incomeStatement, contains: "法人税"),
                "rd": firstByLabel(year.incomeStatement, contains: "研究開発"),
                "employees": nil,
                "interest_expense": firstByLabel(year.incomeStatement, contains: "支払利息")
                    ?? firstByLabel(year.incomeStatement, contains: "利息費用"),
                "cf_treasury_stock": firstByLabel(year.cashFlow, contains: "自己株式"),
                "dividend_ss": firstByLabel(year.changesInEquity, contains: "配当"),
            ]
        }

        let statementTags = Set(
            (year.balanceSheet + year.incomeStatement + year.cashFlow + year.changesInEquity)
                .map(\.tag))
        let masked = allTags.filter { statementTags.contains($0.key) }
        let durationFS = fieldSetFromDuration(masked)
        let instantFS = fieldSetFromInstant(masked)
        let gp = GrossProfitExtractor.extract(
            fieldSet: durationFS, accountingStandard: std, xbrlDir: nil)
        let op = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let cf = CashFlowExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ibd = IBDExtractor.extract(
            fieldSet: instantFS, accountingStandard: std, xbrlDir: nil)
        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let rd = RDExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let emp = EmployeesExtractor.extract(fieldSet: instantFS, tagElements: masked)
        let ie = InterestExpenseExtractor.extract(
            fieldSet: durationFS, accountingStandard: std, xbrlDir: nil)
        let cfTs = CfTreasuryStockExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(masked)
        let equityAttrFS = fieldSetFromIFRSEquityAttributable(masked)
        let divSS = DividendSSExtractor.extract(
            fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS,
            accountingStandard: std)
        return [
            "gross_profit": gp.grossProfit,
            "sga": op.sga,
            "cfo": cf.cfo,
            "cfi": cf.cfi,
            "ibd": ibd.total,
            "pretax_income": tax.pretaxIncome,
            "income_tax": tax.incomeTax,
            "rd": rd.current,
            "employees": emp.current,
            "interest_expense": ie.current,
            "cf_treasury_stock": cfTs.current,
            "dividend_ss": divSS.current,
        ]
    }

    /// 0101010 相当の `*SummaryOfBusinessResults` タグだけを読んだ場合の未移行フィールド。
    private func summaryTagRemainingValues(xbrlDir: URL) -> [String: Double?] {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        let summaryOnly = allTags.filter { $0.key.contains("SummaryOfBusinessResults") }
        let durationFS = fieldSetFromDuration(summaryOnly)
        let instantFS = fieldSetFromInstant(summaryOnly)
        let gp = GrossProfitExtractor.extract(
            fieldSet: durationFS, accountingStandard: std, xbrlDir: nil)
        let op = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let cf = CashFlowExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ibd = IBDExtractor.extract(
            fieldSet: instantFS, accountingStandard: std, xbrlDir: nil)
        let tax = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let rd = RDExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let emp = EmployeesExtractor.extract(fieldSet: instantFS, tagElements: summaryOnly)
        let ie = InterestExpenseExtractor.extract(
            fieldSet: durationFS, accountingStandard: std, xbrlDir: nil)
        let cfTs = CfTreasuryStockExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(summaryOnly)
        let equityAttrFS = fieldSetFromIFRSEquityAttributable(summaryOnly)
        let divSS = DividendSSExtractor.extract(
            fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS,
            accountingStandard: std)
        return [
            "gross_profit": gp.grossProfit,
            "sga": op.sga,
            "cfo": cf.cfo,
            "cfi": cf.cfi,
            "ibd": ibd.total,
            "pretax_income": tax.pretaxIncome,
            "income_tax": tax.incomeTax,
            "rd": rd.current,
            "employees": emp.current,
            "interest_expense": ie.current,
            "cf_treasury_stock": cfTs.current,
            "dividend_ss": divSS.current,
        ]
    }

    /// 0101010 `*SummaryOfBusinessResults` だけで本表水準値が取れるか。
    private func summaryTagMainTableValues(xbrlDir: URL) -> [String: Double?] {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        let summaryOnly = allTags.filter { $0.key.contains("SummaryOfBusinessResults") }
        let durationFS = fieldSetFromDuration(summaryOnly)
        let instantFS = fieldSetFromInstant(summaryOnly)
        let is_ = IncomeStatementExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let op = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: std)
        let bs = BalanceSheetExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let ppe = TangibleFixedAssetsExtractor.extract(fieldSet: instantFS, accountingStandard: std)
        let cash = resolveItem(instantFS, tags: Xbrl.cashEquivalentsTags)
        return [
            "sales": is_.sales,
            "operating_profit": op.operatingProfit ?? is_.operatingProfit,
            "net_profit": is_.netProfit,
            "total_assets": bs.totalAssets,
            "current_assets": bs.currentAssets,
            "non_current_assets": bs.nonCurrentAssets,
            "current_liabilities": bs.currentLiabilities,
            "non_current_liabilities": bs.nonCurrentLiabilities,
            "net_assets": bs.netAssets,
            "ppe_total": ppe.total,
            "cash_eq": cash.current,
        ]
    }

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
