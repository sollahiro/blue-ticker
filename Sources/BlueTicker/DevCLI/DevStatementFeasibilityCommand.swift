import ArgumentParser
import Foundation

/// 使い捨て調査用コマンド(将来構想の検証専用。マージしない)。
///
/// 「summarize(financials)の各生値項目を、Extractors.swift の直接XBRL解析ではなく Statement
/// (BS/PL/CF の構造化ファクト、StatementClassifier)だけから再現できるか」を実データで測定する。
///
/// 手法: 各書類について「フル FieldSet(今日の実装が使う全タグ)」と「Statement マスク FieldSet
/// (StatementClassifier.extractLineItems が実際に採用したタグだけに絞った FieldSet。値は元の
/// タグ別コンテキストマップをそのまま保持するため、通れば値は完全一致するはず)」の両方で
/// 同じ Extractor 関数(本番コード、無改変)を実行し、fullの結果とmaskedの結果を突き合わせる。
/// xbrlDir を取る Extractor は masked 側で nil を渡し、注記/HTML/明細表フォールバックを無効化する
/// (Statement は BS/PL/CF ロールの XBRL fact のみが対象のため)。
struct DevStatementFeasibilityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statement-feasibility",
        abstract: "summarize の各項目を Statement(BS/PL/CF) だけから再現できるかを実データで検証する(使い捨て調査用)"
    )

    @Option(name: .customLong("cache-dir"), help: "EDINET キャッシュのルート(analysis_cache の親ディレクトリ)")
    var cacheDirPath: String = NSHomeDirectory() + "/.config/blue-ticker/analysis_cache"

    @Option(name: .customLong("limit"), help: "処理する書類数の上限(0 は無制限)")
    var limit: Int = 0

    @Option(name: .customLong("csv-out"), help: "行単位の結果を書き出す CSV パス(空文字なら書き出さない)")
    var csvOut: String = "statement_feasibility_experiment.csv"

    @Option(name: .customLong("debug-doc"), help: "指定した docID の詳細(タグ別role分類)だけを出力する")
    var debugDoc: String?

    @Option(name: .customLong("debug-tags"), help: "--debug-doc と併用。カンマ区切りのタグ名リスト")
    var debugTags: String?

    @Option(name: .customLong("debug-role"), help: "--debug-doc と併用。role名の部分一致でタグを列挙する")
    var debugRole: String?

    @Flag(name: .customLong("debug-employees-breakdown"), help: "--debug-doc と併用。従業員数breakdown軸の解決結果を出力する")
    var debugEmployeesBreakdown = false

    @Flag(name: .customLong("debug-rd-breakdown"), help: "--debug-doc と併用。研究開発費breakdown軸の解決結果を出力する")
    var debugRDBreakdown = false

    @Flag(name: .customLong("debug-sga-breakdown"), help: "--debug-doc と併用。sga_breakdown note_typeの解決結果を出力する")
    var debugSGABreakdown = false

    @Flag(
        name: .customLong("debug-borrowings-schedule"),
        help: "--debug-doc と併用。borrowings_schedule_cf_supplement note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugBorrowingsSchedule = false

    @Flag(
        name: .customLong("debug-policy-holding-securities"),
        help: "--debug-doc と併用。policy_holding_securities note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugPolicyHoldingSecurities = false

    @Flag(
        name: .customLong("debug-dividends"),
        help: "--debug-doc と併用。dividends note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugDividends = false

    @Flag(
        name: .customLong("debug-per-share"),
        help: "--debug-doc と併用。per_share_information note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugPerShare = false

    @Flag(
        name: .customLong("debug-capex"),
        help: "--debug-doc と併用。capital_expenditures_overview note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugCapex = false

    @Flag(
        name: .customLong("debug-issued-shares"),
        help: "--debug-doc と併用。issued_shares note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugIssuedShares = false

    @Flag(
        name: .customLong("debug-ppe-schedule"),
        help: "--debug-doc と併用。property_plant_equipment_schedule note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugPPESchedule = false

    @Flag(
        name: .customLong("debug-goodwill"),
        help: "--debug-doc と併用。goodwill_and_intangibles note_typeの解決結果を出力する(単独ならキャッシュ全走査)"
    )
    var debugGoodwill = false

    @Option(
        name: .customLong("export-notes-review"),
        help: "borrowings_schedule_cf_supplement/property_plant_equipment_schedule/goodwill_and_intangibles をキャッシュ全走査し、提出年度・会社名・結果をJSONで書き出す(ユーザーレビュー用)"
    )
    var exportNotesReviewPath: String?

    func run() async throws {
        let cacheDir = URL(fileURLWithPath: cacheDirPath)
        let xbrlRoot = edinetCacheDir(cacheDir).appendingPathComponent("xbrl", isDirectory: true)
        let fm = FileManager.default

        if let exportNotesReviewPath {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            try Self.exportNotesReview(dirs: dirs, to: URL(fileURLWithPath: exportNotesReviewPath))
            return
        }
        if let debugDoc, let debugRole {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugDumpByRole(docID: debugDoc, xbrlDir: dir, roleSubstring: debugRole)
            return
        }
        if let debugDoc, debugEmployeesBreakdown {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugEmployeesBreakdown(docID: debugDoc, xbrlDir: dir)
            return
        }
        if let debugDoc, debugRDBreakdown {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugRDBreakdown(docID: debugDoc, xbrlDir: dir)
            return
        }
        if let debugDoc, debugSGABreakdown {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugSGABreakdown(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugSGABreakdown {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolveSGABreakdown(xbrlDir: dir) {
                case .resolved: resolvedCount += 1
                case .notApplicable: notApplicableCount += 1; print("notApplicable: \(docID)")
                case .failed: break
                }
            }
            print("resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count)")
            return
        }
        if let debugDoc, debugBorrowingsSchedule {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            switch StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(xbrlDir: dir) {
            case .resolved(let payload, let source, let contentHash):
                print("source=\(source) contentHash=\(contentHash)")
                for c in payload.borrowingsComponents ?? [] {
                    print(
                        "  label=\(c.label) prior=\(c.priorBalance.map { String($0) } ?? "-") current=\(c.currentBalance.map { String($0) } ?? "-") rate%=\(c.averageInterestRatePercent.map { String($0) } ?? "-") isTotal=\(c.isTotal)"
                    )
                }
            case .notApplicable(let reason):
                print("notApplicable(\(reason))")
            case .failed:
                print("failed")
            }
            return
        }
        if debugDoc == nil, debugBorrowingsSchedule {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(xbrlDir: dir) {
                case .resolved: resolvedCount += 1; print("resolved: \(docID)")
                case .notApplicable: notApplicableCount += 1
                case .failed: break
                }
            }
            print("resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count)")
            return
        }
        if let debugDoc, debugPolicyHoldingSecurities {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugPolicyHoldingSecurities(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugPolicyHoldingSecurities {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            var totalSecurities = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: dir) {
                case .resolved(let payload, _, _):
                    resolvedCount += 1
                    totalSecurities += payload.securities?.count ?? 0
                case .notApplicable:
                    notApplicableCount += 1
                    print("notApplicable: \(docID)")
                case .failed: break
                }
            }
            print("resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count) totalSecurities=\(totalSecurities)")
            return
        }
        if let debugDoc, debugDividends {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugDividends(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugDividends {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            var totalEvents = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolveDividends(xbrlDir: dir) {
                case .resolved(let payload, _, _):
                    resolvedCount += 1
                    totalEvents += payload.dividendEvents?.count ?? 0
                case .notApplicable:
                    notApplicableCount += 1
                    print("notApplicable: \(docID)")
                case .failed: break
                }
            }
            print("resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count) totalEvents=\(totalEvents)")
            return
        }
        if let debugDoc, debugPerShare {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugPerShare(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugPerShare {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            var withBps = 0
            var withDilutedEps = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolvePerShareInformation(xbrlDir: dir) {
                case .resolved(let payload, _, _):
                    resolvedCount += 1
                    let tags = Set((payload.items ?? []).map(\.tag))
                    if tags.contains("bps") { withBps += 1 }
                    if tags.contains("diluted_eps") { withDilutedEps += 1 }
                case .notApplicable:
                    notApplicableCount += 1
                    print("notApplicable: \(docID)")
                case .failed: break
                }
            }
            print(
                "resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count) withBps=\(withBps) withDilutedEps=\(withDilutedEps)"
            )
            return
        }
        if let debugDoc, debugCapex {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugCapex(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugCapex {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            var withTable = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: dir) {
                case .resolved(let payload, _, _):
                    resolvedCount += 1
                    let segments = payload.capexSegments ?? []
                    if segments.contains(where: { $0.segmentName != nil }) { withTable += 1 }
                case .notApplicable:
                    notApplicableCount += 1
                    print("notApplicable: \(docID)")
                case .failed: break
                }
            }
            print(
                "resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count) withTable=\(withTable)"
            )
            return
        }
        if let debugDoc, debugIssuedShares {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugIssuedShares(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugIssuedShares {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolveIssuedShares(xbrlDir: dir) {
                case .resolved:
                    resolvedCount += 1
                case .notApplicable:
                    notApplicableCount += 1
                    print("notApplicable: \(docID)")
                case .failed: break
                }
            }
            print("resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count)")
            return
        }
        if let debugDoc, debugPPESchedule {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugPPESchedule(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugPPESchedule {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolvePropertyPlantEquipmentSchedule(xbrlDir: dir) {
                case .resolved(let payload, _, _):
                    resolvedCount += 1
                    print("resolved: \(docID) items=\(payload.items?.count ?? 0)")
                case .notApplicable: notApplicableCount += 1
                case .failed: break
                }
            }
            print("resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count)")
            return
        }
        if let debugDoc, debugGoodwill {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            Self.debugGoodwill(docID: debugDoc, xbrlDir: dir)
            return
        }
        if debugDoc == nil, debugGoodwill {
            guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil)
            else { return }
            let dirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var resolvedCount = 0
            var notApplicableCount = 0
            for dir in dirs {
                let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
                switch StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: dir) {
                case .resolved(let payload, _, _):
                    resolvedCount += 1
                    print("resolved: \(docID) items=\(payload.items?.count ?? 0)")
                case .notApplicable: notApplicableCount += 1
                case .failed: break
                }
            }
            print("resolved=\(resolvedCount) notApplicable=\(notApplicableCount) total=\(dirs.count)")
            return
        }
        if let debugDoc {
            let dir = xbrlRoot.appendingPathComponent("\(debugDoc)_xbrl", isDirectory: true)
            let tags = (debugTags ?? "").split(separator: ",").map(String.init)
            Self.debugDump(docID: debugDoc, xbrlDir: dir, tags: tags)
            return
        }
        guard let entries = try? fm.contentsOfDirectory(at: xbrlRoot, includingPropertiesForKeys: nil) else {
            printError("エラー: XBRL キャッシュディレクトリが見つかりません: \(xbrlRoot.path)\n")
            throw ExitCode.failure
        }
        var docDirs = entries.filter { $0.lastPathComponent.hasSuffix("_xbrl") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if limit > 0 { docDirs = Array(docDirs.prefix(limit)) }

        printError("対象書類数: \(docDirs.count)\n")

        var rows: [FeasibilityRow] = []
        var processed = 0
        for dir in docDirs {
            let docID = String(dir.lastPathComponent.dropLast("_xbrl".count))
            guard let docRows = Self.analyzeDocument(docID: docID, xbrlDir: dir) else { continue }
            rows.append(contentsOf: docRows)
            processed += 1
            if processed % 10 == 0 { printError("  \(processed)/\(docDirs.count) 件処理済み\n") }
        }
        printError("解析完了: \(processed)/\(docDirs.count) 件(fact抽出成功)\n\n")

        Self.printSummary(rows)

        if !csvOut.isEmpty {
            try Self.writeCSV(rows, to: URL(fileURLWithPath: csvOut))
            printError("\nCSV出力: \(csvOut)\n")
        }
    }

    // MARK: - 1書類分の解析

    struct FeasibilityRow {
        var docID: String
        var accountingStandard: String
        var field: String
        var todayValue: Double?
        var statementValue: Double?

        var todayFound: Bool { todayValue != nil }
        var statementFound: Bool { statementValue != nil }
        var matches: Bool {
            guard let t = todayValue, let s = statementValue else { return false }
            return abs(t - s) <= max(abs(t), 1) * 1e-9
        }
    }

    static func analyzeDocument(docID: String, xbrlDir: URL) -> [FeasibilityRow]? {
        // 今日の実装と同じ構築(IndividualAnalyzer.processDocument 相当)
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        guard !allTagElements.isEmpty else { return nil }
        let accountingStandard = detectAccountingStandard(allTagElements)

        var durationFS = fieldSetFromDuration(allTagElements)
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(allTagElements)
        let equityAttrFS = fieldSetFromIFRSEquityAttributable(allTagElements)
        var instantFS = fieldSetFromInstant(allTagElements)
        if accountingStandard == "US-GAAP" {
            for (tag, fv) in USGAAPHtml.parsePLFields(in: xbrlDir) { durationFS[tag] = fv }
            for (tag, fv) in USGAAPHtml.parseBSFields(in: xbrlDir) { instantFS[tag] = fv }
        }

        // Statement(StatementClassifier)が実際に採用するタグ集合を求める
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        let bsItems = StatementClassifier.extractLineItems(from: facts, sectionType: .balanceSheet)
        let plItems = StatementClassifier.extractLineItems(from: facts, sectionType: .incomeStatement)
        let cfItems = StatementClassifier.extractLineItems(from: facts, sectionType: .cashFlow)
        let statementTags = Set(bsItems.map(\.tag) + plItems.map(\.tag) + cfItems.map(\.tag))

        // Statement マスク: 採用タグのみ、コンテキストマップは元のまま保持(値は劣化させない)
        let maskedTagElements = allTagElements.filter { statementTags.contains($0.key) }
        let maskedDurationFS = fieldSetFromDuration(maskedTagElements)
        let maskedNcDurationFS = fieldSetFromNonConsolidatedDuration(maskedTagElements)
        let maskedEquityAttrFS = fieldSetFromIFRSEquityAttributable(maskedTagElements)
        let maskedInstantFS = fieldSetFromInstant(maskedTagElements)
        // US-GAAP HTML由来の仮想タグは XBRL fact ではないため Statement 側には存在しない(注入しない)

        var rows: [FeasibilityRow] = []
        func add(_ field: String, _ today: Double?, _ statement: Double?) {
            rows.append(FeasibilityRow(
                docID: docID, accountingStandard: accountingStandard, field: field,
                todayValue: today, statementValue: statement))
        }

        let isReal = IncomeStatementExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let isMasked = IncomeStatementExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("sales", isReal.sales, isMasked.sales)
        add("operating_profit_is", isReal.operatingProfit, isMasked.operatingProfit)
        add("net_profit", isReal.netProfit, isMasked.netProfit)

        let cfReal = CashFlowExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let cfMasked = CashFlowExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("cfo", cfReal.cfo, cfMasked.cfo)
        add("cfi", cfReal.cfi, cfMasked.cfi)

        let gpReal = GrossProfitExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard, xbrlDir: xbrlDir)
        let gpMasked = GrossProfitExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard, xbrlDir: nil)
        add("gross_profit", gpReal.grossProfit, gpMasked.grossProfit)

        let opReal = OperatingProfitExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let opMasked = OperatingProfitExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("operating_profit", opReal.operatingProfit, opMasked.operatingProfit)
        add("sga", opReal.sga, opMasked.sga)

        let bsReal = BalanceSheetExtractor.extract(fieldSet: instantFS, accountingStandard: accountingStandard)
        let bsMasked = BalanceSheetExtractor.extract(fieldSet: maskedInstantFS, accountingStandard: accountingStandard)
        add("total_assets", bsReal.totalAssets, bsMasked.totalAssets)
        add("current_assets", bsReal.currentAssets, bsMasked.currentAssets)
        add("non_current_assets", bsReal.nonCurrentAssets, bsMasked.nonCurrentAssets)
        add("current_liabilities", bsReal.currentLiabilities, bsMasked.currentLiabilities)
        add("non_current_liabilities", bsReal.nonCurrentLiabilities, bsMasked.nonCurrentLiabilities)
        add("net_assets", bsReal.netAssets, bsMasked.netAssets)

        let ibdReal = IBDExtractor.extract(fieldSet: instantFS, accountingStandard: accountingStandard, xbrlDir: xbrlDir)
        let ibdMasked = IBDExtractor.extract(fieldSet: maskedInstantFS, accountingStandard: accountingStandard, xbrlDir: nil)
        add("interest_bearing_debt", ibdReal.total, ibdMasked.total)

        let empReal = EmployeesExtractor.extract(fieldSet: instantFS, tagElements: allTagElements)
        let empMasked = EmployeesExtractor.extract(fieldSet: maskedInstantFS, tagElements: maskedTagElements)
        add("employees", empReal.current, empMasked.current)

        let taxReal = TaxExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let taxMasked = TaxExpenseExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("pretax_income", taxReal.pretaxIncome, taxMasked.pretaxIncome)
        add("income_tax", taxReal.incomeTax, taxMasked.incomeTax)

        let ieReal = InterestExpenseExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard, xbrlDir: xbrlDir)
        let ieMasked = InterestExpenseExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard, xbrlDir: nil)
        add("interest_expense", ieReal.current, ieMasked.current)

        let ppeReal = TangibleFixedAssetsExtractor.extract(fieldSet: instantFS, accountingStandard: accountingStandard)
        let ppeMasked = TangibleFixedAssetsExtractor.extract(fieldSet: maskedInstantFS, accountingStandard: accountingStandard)
        add("ppe_total", ppeReal.total, ppeMasked.total)

        let capexReal = CapexExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let capexMasked = CapexExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("capex", capexReal.current, capexMasked.current)

        let rdReal = RDExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let rdMasked = RDExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("rd", rdReal.current, rdMasked.current)

        let bbReal = ShareBuybackExtractor.extract(
            fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS,
            accountingStandard: accountingStandard)
        let bbMasked = ShareBuybackExtractor.extract(
            fieldSet: maskedDurationFS, ncFieldSet: maskedNcDurationFS,
            equityAttributableFieldSet: maskedEquityAttrFS, accountingStandard: accountingStandard)
        add("buyback", bbReal.current, bbMasked.current)

        let cfTsReal = CfTreasuryStockExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let cfTsMasked = CfTreasuryStockExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("cf_treasury_stock", cfTsReal.current, cfTsMasked.current)

        let divSSReal = DividendSSExtractor.extract(
            fieldSet: durationFS, ncFieldSet: ncDurationFS, equityAttributableFieldSet: equityAttrFS,
            accountingStandard: accountingStandard)
        let divSSMasked = DividendSSExtractor.extract(
            fieldSet: maskedDurationFS, ncFieldSet: maskedNcDurationFS,
            equityAttributableFieldSet: maskedEquityAttrFS, accountingStandard: accountingStandard)
        add("dividend_ss", divSSReal.current, divSSMasked.current)

        let divPaidReal = DividendPaidExtractor.extract(fieldSet: durationFS, accountingStandard: accountingStandard)
        let divPaidMasked = DividendPaidExtractor.extract(fieldSet: maskedDurationFS, accountingStandard: accountingStandard)
        add("dividend_paid_cf", divPaidReal.current, divPaidMasked.current)

        let arReal = AccountsReceivableExtractor.extract(fieldSet: instantFS, accountingStandard: accountingStandard)
        let arMasked = AccountsReceivableExtractor.extract(fieldSet: maskedInstantFS, accountingStandard: accountingStandard)
        add("accounts_receivable", arReal.current, arMasked.current)

        let invReal = InventoryExtractor.extract(fieldSet: instantFS, accountingStandard: accountingStandard)
        let invMasked = InventoryExtractor.extract(fieldSet: maskedInstantFS, accountingStandard: accountingStandard)
        add("inventory", invReal.current, invMasked.current)

        let apReal = AccountsPayableExtractor.extract(fieldSet: instantFS, accountingStandard: accountingStandard)
        let apMasked = AccountsPayableExtractor.extract(fieldSet: maskedInstantFS, accountingStandard: accountingStandard)
        add("accounts_payable", apReal.current, apMasked.current)

        let psReal = PerShareExtractor.extract(durationFS: durationFS, tagElements: allTagElements)
        let psMasked = PerShareExtractor.extract(durationFS: maskedDurationFS, tagElements: maskedTagElements)
        add("eps", psReal.eps, psMasked.eps)
        add("issued_shares", psReal.issuedShares, psMasked.issuedShares)

        let cashReal = resolveItem(instantFS, tags: Xbrl.cashEquivalentsTags)
        let cashMasked = resolveItem(maskedInstantFS, tags: Xbrl.cashEquivalentsTags)
        add("cash_equivalents", cashReal.current, cashMasked.current)

        return rows
    }

    // MARK: - デバッグ(1書類・指定タグの role 分類を出力)

    static func debugDump(docID: String, xbrlDir: URL, tags: [String]) {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        for tag in tags {
            guard let ctxMap = facts[tag] else {
                print("\(tag): fact無し")
                continue
            }
            print("\(tag): \(ctxMap.count)コンテキスト")
            for (ctx, fact) in ctxMap.sorted(by: { $0.key < $1.key }) {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                let classified = roles.map { r -> String in
                    let sec = StatementClassifier.classify(role: r)
                    return "\(XBRLUtils.sectionNameFromRole(r))=>\(sec.map { String(describing: $0) } ?? "nil")"
                }
                print("  ctx=\(ctx) value=\(fact.value) roles=[\(classified.joined(separator: "; "))]")
            }
        }
    }

    // MARK: - デバッグ(role名の部分一致でタグを列挙)

    static func debugDumpByRole(docID: String, xbrlDir: URL, roleSubstring: String) {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        var matched: [(tag: String, ctx: String, value: Double, role: String, label: String?)] = []
        for (tag, ctxMap) in facts {
            for (ctx, fact) in ctxMap {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                for r in roles where XBRLUtils.sectionNameFromRole(r).contains(roleSubstring) {
                    matched.append((tag, ctx, fact.value, XBRLUtils.sectionNameFromRole(r), fact.label))
                }
            }
        }
        matched.sort { $0.tag == $1.tag ? $0.ctx < $1.ctx : $0.tag < $1.tag }
        print("=== role に \"\(roleSubstring)\" を含むfact: \(matched.count)件 ===")
        for m in matched {
            print("  \(m.tag) [\(m.label ?? "?")] ctx=\(m.ctx) value=\(m.value) role=\(m.role)")
        }
    }

    // MARK: - デバッグ(従業員数breakdown軸)

    static func debugEmployeesBreakdown(docID: String, xbrlDir: URL) {
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords, contextMap: contextMap)
        let employeeFacts = facts.filter { Xbrl.employeeTags.contains($0.tag) }
        print("employees dimensioned facts: \(employeeFacts.count)件")
        for f in employeeFacts {
            print("  tag=\(f.tag) ctx=\(f.contextRef) dims=\(f.dimensions) value=\(f.value)")
        }
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let total = EmployeesExtractor.extract(
            fieldSet: fieldSetFromInstant(allTagElements), tagElements: allTagElements
        ).current
        print("全社合計(非dimension fact): \(total.map { String($0) } ?? "nil")")
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        guard
            let snapshot = BreakdownNormalizer.normalizeEmployees(
                facts: facts, total: total, axis: breakdownAxisEmployees, labelsByTag: labelsByTag)
        else {
            print("normalizeEmployees: nil")
            return
        }
        print("axis=\(snapshot.axis) denominator=\(snapshot.denominator) denominatorTag=\(snapshot.denominatorTag) needsReview=\(snapshot.needsReview) warnings=\(snapshot.warnings)")
        for row in snapshot.rows {
            print("  - label=\(row.labelRaw)(\(row.label ?? "-")) amount=\(row.amount) share=\(row.share.map { String(format: "%.4f", $0) } ?? "-") rowKind=\(row.rowKind)")
        }
    }

    // MARK: - デバッグ(研究開発費breakdown軸)

    static func debugRDBreakdown(docID: String, xbrlDir: URL) {
        let contextMap = BreakdownExtractor.loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = BreakdownExtractor.extractFactsByDimension(
            xbrlDir: xbrlDir, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords, contextMap: contextMap)
        let rdTags = Xbrl.rdExpenseCommonTags + Xbrl.rdExpenseJGAAPTags + Xbrl.rdExpenseIFRSTags
        let rdFacts = facts.filter { rdTags.contains($0.tag) }
        print("rd dimensioned facts: \(rdFacts.count)件")
        for f in rdFacts {
            print("  tag=\(f.tag) ctx=\(f.contextRef) dims=\(f.dimensions) value=\(f.value)")
        }
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let accountingStandard = detectAccountingStandard(allTagElements)
        let total = RDExtractor.extract(
            fieldSet: fieldSetFromDuration(allTagElements), accountingStandard: accountingStandard
        ).current
        print("全社合計(非dimension fact): \(total.map { String($0) } ?? "nil")")
        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        guard
            let snapshot = BreakdownNormalizer.normalizeResearchAndDevelopment(
                facts: facts, total: total, axis: breakdownAxisResearchAndDevelopment,
                labelsByTag: labelsByTag)
        else {
            print("normalizeResearchAndDevelopment: nil")
            return
        }
        print("axis=\(snapshot.axis) denominator=\(snapshot.denominator) denominatorTag=\(snapshot.denominatorTag) needsReview=\(snapshot.needsReview) warnings=\(snapshot.warnings)")
        for row in snapshot.rows {
            print("  - label=\(row.labelRaw)(\(row.label ?? "-")) amount=\(row.amount) share=\(row.share.map { String(format: "%.4f", $0) } ?? "-") rowKind=\(row.rowKind)")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み sga_breakdown note_type)

    static func debugSGABreakdown(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolveSGABreakdown(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            print("source=\(source) contentHash=\(contentHash)")
            for item in payload.items ?? [] {
                print("  tag=\(item.tag) label=\(item.label ?? "?") value=\(item.value) unit=\(item.unit ?? "-")")
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み policy_holding_securities note_type)

    static func debugPolicyHoldingSecurities(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolvePolicyHoldingSecurities(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            let securities = payload.securities ?? []
            print("source=\(source) contentHash=\(contentHash.prefix(40))... count=\(securities.count)")
            for s in securities {
                print("  issuer=\(s.issuerName) shares=\(s.numberOfShares.map { String($0) } ?? "-") carryingAmount=\(s.carryingAmount.map { String($0) } ?? "-") purpose=\((s.purpose ?? "-").prefix(40))")
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み dividends note_type)

    static func debugDividends(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolveDividends(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            let events = payload.dividendEvents ?? []
            print("source=\(source) contentHash=\(contentHash) count=\(events.count)")
            for e in events {
                print("  date=\(e.resolutionDate ?? "-") body=\(e.resolutionBody ?? "-") perShare=\(e.dividendPerShare.map { String($0) } ?? "-") total=\(e.totalAmount.map { String($0) } ?? "-")")
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み per_share_information note_type)

    static func debugPerShare(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolvePerShareInformation(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            print("source=\(source) contentHash=\(contentHash)")
            for item in payload.items ?? [] {
                print("  tag=\(item.tag) label=\(item.label ?? "?") value=\(item.value) unit=\(item.unit ?? "-")")
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み capital_expenditures_overview note_type)

    static func debugCapex(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolveCapitalExpendituresOverview(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            print("source=\(source) contentHash=\(contentHash)")
            for s in payload.capexSegments ?? [] {
                print(
                    "  segment=\(s.segmentName ?? "(total)") amount=\(s.investmentAmount.map { String($0) } ?? "-") yoy=\(s.yoyPercent.map { String($0) } ?? "-") isTotal=\(s.isTotal) desc=\((s.description ?? "-").prefix(30))"
                )
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み issued_shares note_type)

    static func debugIssuedShares(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolveIssuedShares(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            let events = payload.issuedSharesEvents ?? []
            print("source=\(source) contentHash=\(contentHash) count=\(events.count)")
            for e in events {
                print(
                    "  date=\(e.date) sharesDelta=\(e.sharesDelta.map { String($0) } ?? "-") sharesBalance=\(e.sharesBalance.map { String($0) } ?? "-") capitalDelta=\(e.capitalDelta.map { String($0) } ?? "-") capitalBalance=\(e.capitalBalance.map { String($0) } ?? "-") reserveDelta=\(e.capitalReserveDelta.map { String($0) } ?? "-") reserveBalance=\(e.capitalReserveBalance.map { String($0) } ?? "-")"
                )
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み property_plant_equipment_schedule note_type)

    static func debugPPESchedule(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolvePropertyPlantEquipmentSchedule(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            print("source=\(source) contentHash=\(contentHash)")
            for item in payload.items ?? [] {
                print("  tag=\(item.tag) label=\(item.label ?? "?") value=\(item.value) unit=\(item.unit ?? "-")")
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - デバッグ(財務諸表注記取り込み goodwill_and_intangibles note_type)

    static func debugGoodwill(docID: String, xbrlDir: URL) {
        switch StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: xbrlDir) {
        case .resolved(let payload, let source, let contentHash):
            print("source=\(source) contentHash=\(contentHash)")
            for item in payload.items ?? [] {
                print("  tag=\(item.tag) label=\(item.label ?? "?") value=\(item.value) unit=\(item.unit ?? "-")")
            }
        case .notApplicable(let reason):
            print("notApplicable(\(reason))")
        case .failed:
            print("failed")
        }
    }

    // MARK: - ユーザーレビュー用エクスポート(borrowings_schedule_cf_supplement / property_plant_equipment_schedule / goodwill_and_intangibles)

    private struct NotesReviewRow: Encodable {
        var docID: String
        var filerName: String?
        var fiscalYearEnd: String?
        var result: String
        var reason: String?
        var items: [StatementLineItem]?
        var borrowingsComponents: [BorrowingsComponentPayload]?

        private enum CodingKeys: String, CodingKey {
            case docID = "doc_id"
            case filerName = "filer_name"
            case fiscalYearEnd = "fiscal_year_end"
            case result, reason, items
            case borrowingsComponents = "borrowings_components"
        }
    }

    /// 提出書類の表紙情報(DEI)から会社名・決算期末日を読む。提出書類本体(PublicDoc)以外
    /// (AuditDoc等)には jpdei_cor タグが無いため、含む最初のファイルで確定する。
    private static func coverInfo(xbrlDir: URL) -> (filerName: String?, fiscalYearEnd: String?) {
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file),
                let text = String(data: data, encoding: .utf8),
                text.contains("jpdei_cor:FilerNameInJapaneseDEI")
            else { continue }
            let filerName = extractDEITagText(text, tag: "FilerNameInJapaneseDEI")
            let fiscalYearEnd =
                extractDEITagText(text, tag: "CurrentFiscalYearEndDateDEI")
                ?? extractDEITagText(text, tag: "CurrentPeriodEndDateDEI")
            return (filerName, fiscalYearEnd)
        }
        return (nil, nil)
    }

    private static func extractDEITagText(_ xml: String, tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: ":\(tag)[^>]*>([^<]*)<") else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), let r = Range(match.range(at: 1), in: xml)
        else { return nil }
        return String(xml[r])
    }

    private static func notesReviewRows(
        dirs: [URL], resolve: (URL) -> StatementNoteResolveResult
    ) -> [NotesReviewRow] {
        dirs.map { dir in
            let docID = dir.lastPathComponent.replacingOccurrences(of: "_xbrl", with: "")
            let cover = coverInfo(xbrlDir: dir)
            switch resolve(dir) {
            case .resolved(let payload, _, _):
                return NotesReviewRow(
                    docID: docID, filerName: cover.filerName, fiscalYearEnd: cover.fiscalYearEnd,
                    result: "resolved", reason: nil, items: payload.items,
                    borrowingsComponents: payload.borrowingsComponents)
            case .notApplicable(let reason):
                return NotesReviewRow(
                    docID: docID, filerName: cover.filerName, fiscalYearEnd: cover.fiscalYearEnd,
                    result: "not_applicable", reason: reason, items: nil, borrowingsComponents: nil)
            case .failed:
                return NotesReviewRow(
                    docID: docID, filerName: cover.filerName, fiscalYearEnd: cover.fiscalYearEnd,
                    result: "failed", reason: nil, items: nil, borrowingsComponents: nil)
            }
        }
    }

    static func exportNotesReview(dirs: [URL], to url: URL) throws {
        let borrowings = notesReviewRows(dirs: dirs) {
            StatementNotesResolver.resolveBorrowingsScheduleCFSupplement(xbrlDir: $0)
        }
        let ppe = notesReviewRows(dirs: dirs) { StatementNotesResolver.resolvePropertyPlantEquipmentSchedule(xbrlDir: $0) }
        let goodwill = notesReviewRows(dirs: dirs) { StatementNotesResolver.resolveGoodwillAndIntangibles(xbrlDir: $0) }

        let payload: [String: [NotesReviewRow]] = [
            "borrowings_schedule_cf_supplement": borrowings,
            "property_plant_equipment_schedule": ppe,
            "goodwill_and_intangibles": goodwill,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url)
        printError("書き出し完了: \(url.path)\n")
    }

    // MARK: - 集計・出力

    static func printSummary(_ rows: [FeasibilityRow]) {
        let fields = Array(Set(rows.map(\.field))).sorted()
        print("=== フィールド別: Statement(BS/PL/CF) だけで再現できた割合 ===")
        print("(母数=「今日の実装で値が取れた」書類数のみ。対象外企業は含めない)")
        var totalToday = 0
        var totalOK = 0
        for field in fields {
            let inField = rows.filter { $0.field == field }
            let todayOK = inField.filter(\.todayFound)
            let padded = field.padding(toLength: 24, withPad: " ", startingAt: 0)
            guard !todayOK.isEmpty else {
                print("  \(padded) today=0件(対象データ無し)")
                continue
            }
            let statementOK = todayOK.filter(\.matches)
            totalToday += todayOK.count
            totalOK += statementOK.count
            let pct = Double(statementOK.count) / Double(todayOK.count) * 100
            let pctStr = String(format: "%.0f", pct)
            print("  \(padded) today=\(todayOK.count)件  statementOK=\(statementOK.count)件  (\(pctStr)%)")
        }
        if totalToday > 0 {
            let overall = Double(totalOK) / Double(totalToday) * 100
            let overallStr = String(format: "%.1f", overall)
            print("\n=== 全体(フィールド×書類の単純平均): \(overallStr)% (\(totalOK)/\(totalToday)) ===")
        }

        print("\n=== 会計基準別 ===")
        let standards = Array(Set(rows.map(\.accountingStandard))).sorted()
        for std in standards {
            let inStd = rows.filter { $0.accountingStandard == std && $0.todayFound }
            guard !inStd.isEmpty else { continue }
            let ok = inStd.filter(\.matches)
            let pct = Double(ok.count) / Double(inStd.count) * 100
            let pctStr = String(format: "%.1f", pct)
            print("  \(std): \(pctStr)% (\(ok.count)/\(inStd.count))")
        }
    }

    static func writeCSV(_ rows: [FeasibilityRow], to url: URL) throws {
        var lines = ["doc_id,accounting_standard,field,today_value,statement_value,today_found,statement_found,matches"]
        for r in rows {
            let today = r.todayValue.map { String($0) } ?? ""
            let statement = r.statementValue.map { String($0) } ?? ""
            lines.append(
                "\(r.docID),\(r.accountingStandard),\(r.field),\(today),\(statement),\(r.todayFound),\(r.statementFound),\(r.matches)"
            )
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
