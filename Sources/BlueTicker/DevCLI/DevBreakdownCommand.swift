import ArgumentParser
import Foundation

/// 内訳取り込み の事業別/地域別正規化を目視確認するための開発用コマンド。
///
/// - smoke 経路（既定）: `smoke/breakdown_extraction_expected.json` + `smoke/smoke_expected/` のみ使用。EDINET 不要。
/// - live 経路（`--live`）: EDINET から最新（または指定）有報 XBRL を取得し、
///   `BusinessBreakdownResolver` / `GeographyBreakdownLLMNormalizer` で両軸を正規化する。
/// リポジトリルートで実行すること（smoke 経路は `smoke/` 相対パス依存）。
struct DevBreakdownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breakdown",
        abstract: "内訳取り込み の事業別/地域別正規化を実行し目視確認する（開発用）"
    )

    enum Source: String, ExpressibleByArgument {
        case geography
        case revenueRecognition = "revenue_recognition"

        var goldenKey: String {
            switch self {
            case .geography: return "geography"
            case .revenueRecognition: return "revenue_recognition"
            }
        }
    }

    enum LiveAxis: String, ExpressibleByArgument {
        case all
        case business
        case geography
    }

    @Argument(help: "銘柄コード")
    var code: String

    @Argument(help: "書類ID（smoke 経路では必須。live 経路では省略可＝最新有報）")
    var docID: String?

    @Flag(name: .long, help: "EDINET から XBRL を取得して正規化する（smoke fixture を使わない）")
    var live = false

    @Option(help: "smoke 経路の正規化対象: geography | revenue_recognition")
    var source: Source = .geography

    @Option(help: "live 経路で正規化する軸: all | business | geography")
    var axis: LiveAxis = .all

    @Option(help: "smoke/smoke_expected の連結売上フィクスチャを fy_end で絞り込む（例: 2026-03-31）")
    var fyEnd: String?

    func run() async throws {
        if live {
            try await runLive()
        } else {
            try await runSmoke()
        }
    }

    // MARK: - smoke 経路

    private func runSmoke() async throws {
        guard let docID else {
            printError("エラー: smoke 経路では書類IDが必要です（または --live を指定してください）。\n")
            throw ExitCode.failure
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        guard let golden = try? loadGolden(root: root), let entry = golden[docID],
              let sourceDict = entry[source.goldenKey] as? [String: Any]
        else {
            printError("エラー: \(docID) の smoke/breakdown_extraction_expected.json に \(source.goldenKey) フィクスチャがありません。\n")
            throw ExitCode.failure
        }
        let result = ExtractedBreakdown(dictionary: sourceDict)

        printError("\(source.goldenKey) method: \(result.method)\n")
        printError("候補テーブル数: \(result.tables.count)\n")
        for (i, table) in result.tables.enumerated() {
            printError("  [\(i)] heading=\(table.heading) period=\(table.period ?? "不明")\n")
        }

        guard let sales = loadSales(root: root, code: code, fyEnd: fyEnd) else {
            printError("エラー: \(code) の smoke/smoke_expected に連結売上フィクスチャがありません。\n")
            throw ExitCode.failure
        }
        printError("連結外部売上高（円）: \(Int(sales))\n")

        guard result.method == "html_table" else {
            printError("method が html_table ではないため対象外です。\n")
            return
        }

        let (snapshotOrNil, audit): (BreakdownSnapshot?, LLMBreakdownAudit?)
        switch source {
        case .geography:
            let client = try LLMClientLoader.make(axis: .geography)
            (snapshotOrNil, audit) = await GeographyBreakdownLLMNormalizer.normalize(
                result, consolidatedSales: sales, client: client)
        case .revenueRecognition:
            let client = try LLMClientLoader.make(axis: .business)
            (snapshotOrNil, audit) = await RevenueRecognitionLLMNormalizer.normalize(
                result, consolidatedSales: sales, client: client)
        }

        printAudit(audit)
        guard let snapshot = snapshotOrNil else {
            printError("エラー: LLM 正規化が nil を返しました（非該当・呼び出し失敗・パース不能のいずれか）。\n")
            throw ExitCode.failure
        }
        printSnapshot(snapshot)
    }

    // MARK: - live 経路

    private func runLive() async throws {
        let ctx = try await MetricsLoader.prepare(rawCode: code)
        printError("対象: \(ctx.code) \(ctx.name)\n")

        let targetDocID: String
        if let docID, !docID.isEmpty {
            targetDocID = docID
        } else {
            let docs = await EdinetDiscovery.buildDocumentIndexForCode(
                code: ctx.code, client: ctx.client, analysisYears: 1
            )
            guard let latest = docs.first, let dId = latest["docID"] as? String else {
                printError("書類が見つかりませんでした: \(ctx.code)\n")
                throw ExitCode.failure
            }
            targetDocID = dId
        }
        printError("書類ID: \(targetDocID)\n")

        guard let xbrlDir = await ctx.client.downloadDocument(targetDocID) else {
            printError("XBRLのダウンロードに失敗しました: \(targetDocID)\n")
            throw ExitCode.failure
        }

        guard let sales = await loadLiveSales(ctx: ctx, docID: targetDocID) else {
            printError("エラー: 連結売上高（円）を取得できませんでした。\n")
            throw ExitCode.failure
        }
        printError("連結外部売上高（円）: \(Int(sales))\n")

        // html_table 振分は実行時まで LLM 要否が不明。キー未設定時は決定的経路だけ試し、
        // LLM が必要な時点で失敗させる。軸ごとに別クライアント（命名規約 B）。
        let businessLLM = LLMClientLoader.resolveEndpoint(axis: .business)
            .map { ChatCompletionClient(endpoint: $0) }
        let geographyLLM = LLMClientLoader.resolveEndpoint(axis: .geography)
            .map { ChatCompletionClient(endpoint: $0) }

        let labelsByTag = XBRLUtils.loadLabelsByTag(in: xbrlDir)

        if axis == .all || axis == .business {
            let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)
            printError("\n=== business (segments) method=\(segments.method) ===\n")
            printSegmentPreview(segments)

            if let client = businessLLM {
                let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
                    segments: segments, consolidatedSales: sales, client: client,
                    labelsByTag: labelsByTag
                )
                printError("source: \(source.rawValue)\n")
                printAudit(audit)
                if let snapshot {
                    printSnapshot(snapshot)
                } else {
                    printError("business snapshot: nil\n")
                    printNotApplicableReason(
                        segments: segments, sales: sales, xbrlDir: xbrlDir,
                        llmHint: audit?.notApplicableReason)
                }
            } else if let snapshot = BreakdownNormalizer.normalize(
                          segments, consolidatedSales: sales, labelsByTag: labelsByTag),
                      snapshot.axis == "business" {
                printError("source: xbrl_facts（LLM未設定・決定的経路のみ）\n")
                printSnapshot(snapshot)
            } else if !segments.tables.isEmpty {
                printError(
                    """
                    エラー: business の表フォールバックに LLM が必要です。\
                    XAI_BUSINESS_API_KEY と XAI_BUSINESS_MODEL \
                    （または旧 XAI_API_KEY / XAI_MODEL）を設定してください。

                    """
                )
                throw ExitCode.failure
            } else {
                printError("business snapshot: nil\n")
                printNotApplicableReason(segments: segments, sales: sales, xbrlDir: xbrlDir)
            }
        }

        if axis == .all || axis == .geography {
            let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)
            printError("\n=== geography method=\(geography.method) ===\n")
            printSegmentPreview(geography)

            let (snapshot, source, audit) = await GeographyBreakdownResolver.resolve(
                geography: geography, consolidatedSales: sales,
                client: geographyLLM ?? UnavailableDevChatClient(),
                labelsByTag: labelsByTag
            )
            printError("source: \(source.rawValue)\n")
            printAudit(audit)
            if let snapshot {
                printSnapshot(snapshot)
            } else if geography.method == "not_found" {
                printError("geography: not_found（地域注記なし）\n")
            } else if geography.method == "html_table" || !geography.tables.isEmpty,
                geographyLLM == nil
            {
                printError(
                    """
                    エラー: geography が html_table のため LLM が必要です。\
                    XAI_GEOGRAPHY_API_KEY と XAI_GEOGRAPHY_MODEL を設定してください。

                    """
                )
                throw ExitCode.failure
            } else {
                printError("geography snapshot: nil\n")
            }
        }
    }

    /// IndividualAnalyzer のキャッシュ優先結果から、対象 docID の売上（円）を取る。
    /// RawData.sales は百万円単位なので `millionYen` を掛けて円に戻す。
    /// 窓は `analyzeDefaultYears`（内訳取り込み 保持窓と同じ 6 年）。指定 docID が窓に無い、
    /// または売上未抽出なら nil（最新期へ無言フォールバックしない。issue #160）。
    private func loadLiveSales(ctx: AnalysisContext, docID: String) async -> Double? {
        let analyzer = IndividualAnalyzer(edinetClient: ctx.client, cacheManager: ctx.cacheManager)
        guard let result = await analyzer.analyze(
            code: ctx.code, analysisYears: Api.analyzeDefaultYears, useCache: true
        ).resultOrNil,
            let years = result.years, !years.isEmpty
        else { return nil }

        guard let matched = years.first(where: { $0.calculatedData.docID == docID }),
            let salesMillion = matched.rawData.sales
        else { return nil }
        return salesMillion * Financial.millionYen
    }

    // MARK: - 共有ヘルパ

    private func loadGolden(root: URL) throws -> [String: [String: Any]] {
        let path = root.appendingPathComponent("smoke/breakdown_extraction_expected.json")
        let data = try Data(contentsOf: path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw ExitCode.failure
        }
        return obj
    }

    /// code に複数の fixture ファイルがある場合、fyEnd（例: "2026-03-31"）が指定されていれば
    /// ファイル名の年度部分で絞り込む。未指定時はファイル名でソートした上で売上が取れる最初の
    /// ファイルを決定的に採用する（`BreakdownNormalizerTests.loadSales` と同じ規約。ただし
    /// 同一銘柄に複数年度の fixture がある場合は fyEnd 指定を推奨する）。
    private func loadSales(root: URL, code: String, fyEnd: String?) -> Double? {
        let dir = root.appendingPathComponent("smoke/smoke_expected")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var matches = files.filter { $0.hasPrefix("\(code)_") }.sorted()
        if let fyEnd {
            matches = matches.filter { $0 == "\(code)_\(fyEnd).json" }
        }
        for file in matches {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let income = json["income_statement"] as? [String: Any],
                  let sales = (income["sales"] as? NSNumber)?.doubleValue
            else { continue }
            return sales
        }
        return nil
    }

    private func printSegmentPreview(_ result: ExtractedBreakdown) {
        if result.method == "html_table" {
            printError("候補テーブル数: \(result.tables.count)\n")
            for (i, table) in result.tables.enumerated() {
                printError("  [\(i)] heading=\(table.heading) period=\(table.period ?? "不明")\n")
                printError("\(table.markdown)\n")
            }
        } else if result.method == "xbrl_facts" {
            printError("facts: \(result.facts.count)\n")
            for fact in result.facts {
                printError(
                    "  tag=\(fact.tag) contextRef=\(fact.contextRef) dimensions=\(fact.dimensions) value=\(fact.value) unitRef=\(fact.unitRef ?? "不明")\n"
                )
            }
        }
    }

    /// business snapshot が nil のとき、E（地域のみ）/ F（単一セグメント記載省略）を診断表示する
    /// （issue #130）。`BreakdownExtractor.classifyNotApplicableReason` と同じ判定を ingest 側と共用する。
    /// `llmHint` は html_table 経由で LLM が返した `notApplicableReason`（issue #135）。呼び出し元に
    /// audit が無い経路（xbrl_facts のみ・LLM未設定）では nil のままでよい。
    private func printNotApplicableReason(
        segments: ExtractedBreakdown, sales: Double?, xbrlDir: URL, llmHint: String? = nil
    ) {
        switch BreakdownExtractor.classifyNotApplicableReason(
            segments: segments, consolidatedSales: sales, xbrlDir: xbrlDir, llmHint: llmHint
        ) {
        case .geographyOnly:
            printError("診断(E): 報告セグメントが地域別のみで、business 軸への swap が見つかりませんでした。\n")
        case .singleSegmentDisclosed:
            let disclosure = BreakdownExtractor.detectSingleSegmentDisclosure(xbrlDir: xbrlDir) ?? ""
            printError("診断(F): 単一セグメントのため開示省略と明記されています: \(disclosure)\n")
        case .unknown:
            printError("診断: 該当理由を特定できませんでした（要調査）。\n")
        }
    }

    private func printAudit(_ audit: LLMBreakdownAudit?) {
        guard let audit else { return }
        print("LLM が採用した表: source_table_index=\(audit.sourceTableIndex.map(String.init) ?? "不明") period_column=\(audit.periodColumn ?? "不明") unit=\(audit.unit) profit_disclosed=\(audit.profitDisclosed)")
        print("notes: \(audit.notes)")
    }

    private func printSnapshot(_ snapshot: BreakdownSnapshot) {
        print("axis: \(snapshot.axis)")
        print("sourceKind: \(snapshot.sourceKind)")
        print("denominator（円）: \(Int(snapshot.denominator))")
        print("denominatorTag: \(snapshot.denominatorTag)")
        print("needsReview: \(snapshot.needsReview)")
        print("warnings: \(snapshot.warnings)")
        print("rows:")
        for row in snapshot.rows {
            let shareText = row.share.map { String(format: "%.4f", $0) } ?? "-"
            let profitText = row.profit.map { String(Int($0)) } ?? "-"
            print("  - label=\(row.labelRaw)(\(row.label ?? "-")) amount（円）=\(Int(row.amount)) share=\(shareText) profit=\(profitText) rowKind=\(row.rowKind)")
        }
        let segmentShare = snapshot.rows
            .filter { $0.rowKind == "segment" }
            .compactMap(\.share)
            .reduce(0, +)
        print("segment share sum: \(String(format: "%.4f", segmentShare))")
    }
}

/// DevCLI 用: geography LLM 未設定時に決定的経路だけ試すためのプレースホルダ。
/// Server の `UnavailableChatClient` と同型（意図的に別実装）。
private struct UnavailableDevChatClient: ChatCompleting {
    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        throw ChatCompletionError.invalidResponse
    }
}
