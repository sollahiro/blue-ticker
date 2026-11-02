// 公開 statement の JSON（`GET /v1/companies/{code}/statement` を保存したもの）で、
// 資金配分の決定論がどれだけ内訳を出せるかと、決まらない財務CF行を数える。本番 write はしない。
// BLT_CASH_ALLOCATION_STATEMENT_DIR に JSON のディレクトリを渡したときだけ走る。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct CashAllocationCorpusScanTests {
    @Test func reportCoverageOnSavedStatements() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["BLT_CASH_ALLOCATION_STATEMENT_DIR"]
        else {
            print("SKIP corpus (set BLT_CASH_ALLOCATION_STATEMENT_DIR)")
            return
        }
        let dir = URL(fileURLWithPath: dirPath)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        var years = 0
        var resolved = 0
        var unresolvedRows: [String: Int] = [:]
        var mismatch: [String] = []
        for file in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["years"] as? [[String: Any]]
            else { continue }
            for entry in entries {
                let cashFlow = (entry["cash_flow"] as? [[String: Any]] ?? []).compactMap(Self.item)
                guard !cashFlow.isEmpty,
                      !cashFlow.contains(where: { $0.tag.hasPrefix("USGAAP_HTML_") })
                else { continue }
                years += 1
                let prepared = CashAllocationResolver.prepare(cashFlow: cashFlow, cfo: nil, cfi: nil)
                for row in prepared.rows where row.role == nil {
                    unresolvedRows["\(row.item.tag) \(row.item.label ?? "")", default: 0] += 1
                }
                let values = CashAllocationResolver.values(
                    from: prepared, roles: prepared.rows.map(\.role), isBank: false)
                if values.debtChange != nil {
                    resolved += 1
                } else if prepared.rows.allSatisfy({ $0.role != nil }) {
                    let sum = prepared.rows.reduce(0.0) { $0 + $1.item.value }
                    let gap = prepared.cff.map { (sum - $0) / Financial.millionYen }
                    mismatch.append("\(file) doc=\(entry["doc_id"] ?? "") rows=\(prepared.rows.count) gap_million=\(gap.map { String($0) } ?? "no_cff")")
                }
            }
        }
        print("CASH_ALLOCATION years=\(years) resolved=\(resolved) sum_mismatch=\(mismatch.count)")
        for item in mismatch.prefix(20) { print("MISMATCH \(item)") }
        for (key, count) in unresolvedRows.sorted(by: { $0.value > $1.value }) {
            print("UNRESOLVED \(count) \(key)")
        }
    }

    private static func item(_ raw: [String: Any]) -> StatementLineItem? {
        guard let tag = raw["tag"] as? String else { return nil }
        let value = (raw["value"] as? Double) ?? (raw["value"] as? Int).map(Double.init) ?? 0
        return StatementLineItem(
            tag: tag, label: raw["label"] as? String, value: value,
            unit: raw["unit"] as? String, order: raw["order"] as? Int,
            section: (raw["section"] as? String).map { StatementLineSection(rawValue: $0) },
            isTotal: raw["is_total"] as? Bool ?? false)
    }
}
