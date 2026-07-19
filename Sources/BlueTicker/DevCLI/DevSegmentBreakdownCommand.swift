import ArgumentParser
import Foundation

/// Stage 6 の geography html_table LLM 正規化（`SegmentBreakdownLLMNormalizer`）を
/// smoke fixture に対して実行し、結果を目視確認するための一時的な開発用コマンド。
/// EDINET を叩かない（`smoke/segment_expected.json` + `smoke/smoke_expected/` のみ使用）。
/// リポジトリルートで実行すること（`smoke/` 相対パス依存）。
struct DevSegmentBreakdownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "segment-breakdown",
        abstract: "Stage 6 geography html_table の LLM 正規化を smoke fixture に対して実行し目視確認する（開発用・EDINET不要）"
    )

    @Argument(help: "銘柄コード（smoke/smoke_expected の連結売上フィクスチャ検索キー）")
    var code: String

    @Argument(help: "書類ID（smoke/segment_expected.json のキー）")
    var docID: String

    func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        guard let golden = try? loadGolden(root: root), let entry = golden[docID],
              let geoDict = entry["geography"] as? [String: Any]
        else {
            printError("エラー: \(docID) の smoke/segment_expected.json に geography フィクスチャがありません。\n")
            throw ExitCode.failure
        }
        let result = SegmentResult(dictionary: geoDict)

        printError("geography method: \(result.method)\n")
        printError("候補テーブル数: \(result.tables.count)\n")
        for (i, table) in result.tables.enumerated() {
            printError("  [\(i)] heading=\(table.heading) period=\(table.period ?? "不明")\n")
        }

        guard let sales = loadSales(root: root, code: code) else {
            printError("エラー: \(code) の smoke/smoke_expected に連結売上フィクスチャがありません。\n")
            throw ExitCode.failure
        }
        printError("連結外部売上高（円）: \(Int(sales))\n")

        guard result.method == "html_table" else {
            printError("method が html_table ではないため対象外です。\n")
            return
        }

        let client = try LLMClientLoader.make()
        let (snapshotOrNil, audit) = await SegmentBreakdownLLMNormalizer.normalize(result, consolidatedSales: sales, client: client)

        if let audit {
            print("LLM が採用した表: source_table_index=\(audit.sourceTableIndex.map(String.init) ?? "不明") period_column=\(audit.periodColumn ?? "不明") unit=\(audit.unit)")
            print("notes: \(audit.notes)")
        }

        guard let snapshot = snapshotOrNil else {
            printError("エラー: LLM 正規化が nil を返しました（非該当・呼び出し失敗・パース不能のいずれか）。\n")
            throw ExitCode.failure
        }

        print("axis: \(snapshot.axis)")
        print("denominator（円）: \(Int(snapshot.denominator))")
        print("denominatorTag: \(snapshot.denominatorTag)")
        print("needsReview: \(snapshot.needsReview)")
        print("warnings: \(snapshot.warnings)")
        print("rows:")
        for row in snapshot.rows {
            let shareText = row.share.map { String(format: "%.4f", $0) } ?? "-"
            print("  - label=\(row.labelRaw) amount（円）=\(Int(row.amount)) share=\(shareText) rowKind=\(row.rowKind)")
        }
    }

    private func loadGolden(root: URL) throws -> [String: [String: Any]] {
        let path = root.appendingPathComponent("smoke/segment_expected.json")
        let data = try Data(contentsOf: path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw ExitCode.failure
        }
        return obj
    }

    /// code に複数の fixture ファイルがある場合に備え、ファイル名でソートした上で
    /// 売上が取れる最初のファイルを決定的に採用する（`SegmentNormalizerTests.loadSales` と同じ規約）。
    private func loadSales(root: URL, code: String) -> Double? {
        let dir = root.appendingPathComponent("smoke/smoke_expected")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let matches = files.filter { $0.hasPrefix("\(code)_") }.sorted()
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
}
