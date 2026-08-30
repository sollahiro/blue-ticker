// smoke/breakdown_extraction_expected.json（Python 実装の出力）と tmp_cache/edinet/ の
// キャッシュ済み XBRL から Swift 実装の出力を突き合わせる（SPEC_ORACLE 床の L1 実行器）。
// 対象は有報（通期）のみ。半期/四半期（q2r 等）は含めない。
// BLT_EDINET_API_KEY が設定されていれば不足分を自動ダウンロードする（SmokeCacheSupport）。
// 未設定かつキャッシュも無い docID は個別に SKIP する。
// 成功時の詳細出力は BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct SegmentParityTests {

    @Test func parityWithPythonGolden() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let goldenPath = projectRoot.appendingPathComponent("smoke/breakdown_extraction_expected.json")
        let xbrlBase = SmokeCacheSupport.cacheDir

        guard FileManager.default.fileExists(atPath: goldenPath.path) else {
            TestVerboseLog.print("SKIP   smoke/breakdown_extraction_expected.json が見つかりません")
            return
        }

        let data = try Data(contentsOf: goldenPath)
        let golden = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        await SmokeCacheSupport.ensureCached(golden.keys)

        var diffs: [String] = []
        var checked = 0

        for (docID, expected) in golden.sorted(by: { $0.key < $1.key }) {
            let xbrlDir = xbrlBase.appendingPathComponent("\(docID)_xbrl")
            guard FileManager.default.fileExists(atPath: xbrlDir.path) else {
                TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし")
                continue
            }
            checked += 1

            let actuals = [
                ("segments", BreakdownExtractor.extractSegmentInfo(xbrlDir: xbrlDir)),
                ("geography", BreakdownExtractor.extractGeographyInfo(xbrlDir: xbrlDir)),
            ]
            for (kind, actual) in actuals {
                guard let exp = expected[kind] as? [String: Any] else { continue }
                diffs.append(contentsOf: compare(exp, actual, label: "\(docID).\(kind)"))
            }
        }

        TestVerboseLog.print("PARITY \(checked) docs checked, \(diffs.count) diffs")
        for d in diffs.prefix(20) { TestVerboseLog.print("DIFF   \(d)") }
        // SwiftSoup.Comment との曖昧性を避けるためモジュール修飾する（CI の Xcode で曖昧エラー）
        #expect(diffs.isEmpty, Testing.Comment(rawValue: "パリティ差分:\n" + diffs.joined(separator: "\n")))
    }

    private func compare(_ expected: [String: Any], _ actual: ExtractedBreakdown, label: String) -> [String] {
        var diffs: [String] = []

        let expMethod = expected["method"] as? String ?? ""
        if expMethod != actual.method {
            diffs.append("\(label): method \(expMethod) != \(actual.method)")
            return diffs
        }

        // tables: リスト順も含めて比較
        let expTables = expected["tables"] as? [[String: Any]] ?? []
        if expTables.count != actual.tables.count {
            diffs.append("\(label): tables 件数 \(expTables.count) != \(actual.tables.count)")
        } else {
            for (i, (exp, act)) in zip(expTables, actual.tables).enumerated() {
                if exp["heading"] as? String != act.heading {
                    diffs.append("\(label): tables[\(i)].heading \(exp["heading"] ?? "nil") != \(act.heading)")
                }
                if exp["period"] as? String != act.period {
                    diffs.append("\(label): tables[\(i)].period \(exp["period"] ?? "nil") != \(act.period ?? "nil")")
                }
                if exp["markdown"] as? String != act.markdown {
                    diffs.append("\(label): tables[\(i)].markdown 不一致\n--- expected\n\(exp["markdown"] ?? "")\n--- actual\n\(act.markdown)")
                }
            }
        }

        // facts: 順序不定のため (tag, contextRef) で照合する。
        // 実抽出が Python golden より多い fact を持っていてもよい
        // （dimension なしの連結財務諸表計上額など、後から足した列）。
        let expFacts = (expected["facts"] as? [[String: Any]] ?? []).sorted {
            (($0["tag"] as? String ?? ""), ($0["contextRef"] as? String ?? ""))
                < (($1["tag"] as? String ?? ""), ($1["contextRef"] as? String ?? ""))
        }
        var actualByKey: [String: BreakdownFact] = [:]
        for fact in actual.facts {
            actualByKey["\(fact.tag)|\(fact.contextRef)"] = fact
        }
        for exp in expFacts {
            let tag = exp["tag"] as? String ?? ""
            let contextRef = exp["contextRef"] as? String ?? ""
            let key = "\(label): facts (\(tag), \(contextRef))"
            guard let act = actualByKey["\(tag)|\(contextRef)"] else {
                diffs.append("\(key): 欠落")
                continue
            }
            if exp["dimensions"] as? [String: String] != act.dimensions {
                diffs.append("\(key): dimensions \(exp["dimensions"] ?? [:]) != \(act.dimensions)")
            }
            let expValue = (exp["value"] as? NSNumber)?.doubleValue
            if expValue != act.value {
                diffs.append("\(key): value \(expValue.map { String($0) } ?? "nil") != \(act.value)")
            }
            if let expLabel = exp["label"] as? String, expLabel != (act.label ?? "") {
                diffs.append("\(key): label \(expLabel) != \(act.label ?? "nil")")
            }
            if exp["unitRef"] as? String != act.unitRef {
                diffs.append("\(key): unitRef \(exp["unitRef"] ?? "nil") != \(act.unitRef ?? "nil")")
            }
            if exp["decimals"] as? String != act.decimals {
                diffs.append("\(key): decimals \(exp["decimals"] ?? "nil") != \(act.decimals ?? "nil")")
            }
        }
        return diffs
    }
}
