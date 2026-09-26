// XBRL 再抽出によるヘッダー単位スキャン。CI では走らない。
// `BLT_BREAKDOWN_UNIT_SCAN=1` と R2 XBRL 資格、LLM 行 JSON（`--llm-rows` 相当のファイル）が必要。
// R2 GET のみ（apiKey=nil なので EDINET フォールバックも PUT もしない）。

import Foundation
import Testing
@testable import BlueTickerCore

struct BreakdownUnitScanRow: Codable {
    var code: String
    var docID: String
    var source: String
    var sourceKind: String?
    var llmUnit: String
    var sourceTableIndex: Int?
    var rowCount: Int
    var denominator: Double?
    var maxAmount: Double?

    enum CodingKeys: String, CodingKey {
        case code
        case docID = "doc_id"
        case source
        case sourceKind = "source_kind"
        case llmUnit = "llm_unit"
        case sourceTableIndex = "source_table_index"
        case rowCount = "row_count"
        case denominator
        case maxAmount = "max_amount"
    }
}

@Suite struct BreakdownHeaderUnitLiveScanTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["BLT_BREAKDOWN_UNIT_SCAN"] == "1"
            && R2StorageConfig.resolveXbrlFromEnvironment() != nil
    }

    @Test(
        .enabled(if: enabled, "BLT_BREAKDOWN_UNIT_SCAN=1 and R2 XBRL creds required"),
        .timeLimit(.minutes(30))
    )
    func rescanStoredLLMRowsFromR2HeaderUnit() async throws {
        let env = ProcessInfo.processInfo.environment
        let listPath = env["BLT_BREAKDOWN_UNIT_SCAN_INPUT"]
            ?? "/tmp/breakdown-llm-rows.json"
        let outPath = env["BLT_BREAKDOWN_UNIT_SCAN_OUTPUT"]
            ?? "/opt/cursor/artifacts/breakdown-header-unit-scan.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: listPath))
        let rows = try JSONDecoder().decode([BreakdownUnitScanRow].self, from: data)
        let config = try #require(R2StorageConfig.resolveXbrlFromEnvironment())
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-unit-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let store = EdinetCacheStore(cacheDir: workDir)
        let client = EdinetAPIClient(
            apiKey: nil, cacheStore: store, xbrlObjectStore: R2XbrlObjectStore(config: config))

        var changed: [[String: Any]] = []
        var scanned: [[String: Any]] = []
        var missingXbrl: [String] = []
        var seen = Set<String>()
        var xbrlDirs: [String: URL] = [:]
        for row in rows {
            if xbrlDirs[row.docID] != nil { continue }
            if seen.contains(row.docID) { continue }
            seen.insert(row.docID)
            if let dir = await client.downloadDocument(row.docID, saveDir: workDir) {
                xbrlDirs[row.docID] = dir
            } else {
                missingXbrl.append(row.docID)
            }
        }

        for row in rows {
            guard let section = BreakdownLLMAmountScale.specialSectionKey(source: row.source),
                let xbrlDir = xbrlDirs[row.docID],
                let extracted = BreakdownExtractor.extractSpecialSection(section, xbrlDir: xbrlDir)
            else { continue }
            let header = BreakdownLLMAmountScale.headerUnitToken(
                tables: extracted.tables, sourceTableIndex: row.sourceTableIndex)
            let table: BreakdownTable?
            if let index = row.sourceTableIndex, extracted.tables.indices.contains(index) {
                table = extracted.tables[index]
            } else {
                table = extracted.tables.first
            }
            let markdownRaw = rawAmounts(from: table?.markdown ?? "")
            let rawAmounts = inferredLLMRawAmounts(row: row, markdownRaw: markdownRaw)
            guard !rawAmounts.isEmpty else { continue }
            let old = BreakdownLLMAmountScale.legacyYenMultiplier(
                declaredUnit: row.llmUnit, rawAmounts: rawAmounts, consolidatedSales: row.denominator)
            let new = BreakdownLLMAmountScale.resolve(
                headerToken: header, declaredUnit: row.llmUnit, rawAmounts: rawAmounts,
                consolidatedSales: row.denominator)
            let rawRef = rawAmounts.map { abs($0) }.max() ?? 0
            let newAmount = rawRef * new.multiplier
            let stored = row.maxAmount ?? (rawRef * old.multiplier)
            let ratio = stored == 0 ? 0 : newAmount / stored
            let captions = extracted.tables.map { $0.unitCaption ?? "" }
            let snippets = extracted.tables.prefix(4).map { table in
                String(table.markdown.prefix(160)).replacingOccurrences(of: "\n", with: " | ")
            }
            let record: [String: Any] = [
                "code": row.code,
                "doc_id": row.docID,
                "source_kind": row.sourceKind ?? row.source,
                "source": row.source,
                "row_count": row.rowCount,
                "llm_unit": row.llmUnit,
                "header_unit": header ?? NSNull(),
                "table_count": extracted.tables.count,
                "table_captions": captions,
                "table_snippets": snippets,
                "source_table_index": row.sourceTableIndex ?? NSNull(),
                "old_multiplier": old.multiplier,
                "new_multiplier": new.multiplier,
                "amount_ratio_new_over_old": ratio,
                "header_llm_mismatch": new.headerLlmMismatch,
                "unresolved": new.unresolved,
            ]
            scanned.append(record)
            if abs(ratio - 1) <= 1e-9 { continue }
            changed.append(record)
        }

        let codes = Array(Set(changed.compactMap { $0["code"] as? String })).sorted()
        var byKind: [String: Int] = [:]
        var byRatio: [String: Int] = [:]
        for item in changed {
            let kind = item["source_kind"] as? String ?? ""
            byKind[kind, default: 0] += 1
            if let ratio = item["amount_ratio_new_over_old"] as? Double {
                byRatio[String(format: "%g", ratio), default: 0] += 1
            }
        }
        let artifact: [String: Any] = [
            "summary": [
                "llm_row_count": rows.count,
                "scanned_count": scanned.count,
                "changed_count": changed.count,
                "missing_xbrl": missingXbrl,
                "codes": codes,
                "by_source_kind": byKind,
                "by_ratio": byRatio,
            ],
            "changed": changed,
            "scanned": scanned,
        ]
        let outData = try JSONSerialization.data(
            withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try outData.write(to: URL(fileURLWithPath: outPath))
        print("header-unit scan changed=\(changed.count) codes=\(codes.joined(separator: ","))")
        #expect(missingXbrl.count < rows.count || rows.isEmpty)
    }

    private func rawAmounts(from markdown: String) -> [Double] {
        markdown.split(separator: "\n").flatMap { line in
            line.split(separator: "|").compactMap {
                XBRLUtils.parseHtmlNumber(String($0).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    /// 格納済み金額は既に旧倍率済み。表 markdown の全数値を raw にすると
    /// already-yen が誤爆する。格納 max / 分母から LLM 生値を復元する。
    private func inferredLLMRawAmounts(row: BreakdownUnitScanRow, markdownRaw: [Double]) -> [Double] {
        guard let stored = row.maxAmount else { return markdownRaw }
        let sales = row.denominator
        if row.llmUnit == "million_yen" {
            if let sales, sales != 0 {
                let rel = abs(stored / sales)
                if rel > 10 {
                    return [stored / Financial.millionYen]
                }
                if rel < 0.1 {
                    return [stored]
                }
            }
            return [stored / Financial.millionYen]
        }
        return [stored]
    }
}
