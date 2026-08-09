// assets/nikkei225.csv（ユーザーが用意する優先コード一覧）のパース仕様を検証する。
// Web サイトからのコピペ由来でセクション見出し行・ヘッダー行・改行混入が混在する前提のため、
// 証券コード形式（先頭が数字の英数字4文字）に一致する行だけを拾うことを確認する。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite("loadPriorityIngestCodes")
struct PriorityIngestCodesTests {
    private func withPriorityCSV(_ content: String, _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt_priority_test_\(UUID().uuidString)", isDirectory: true)
        let assetsDir = dir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = assetsDir.appendingPathComponent("nikkei225.csv")
        try Data(content.utf8).write(to: url)
        try body(dir)
    }

    @Test("セクション見出し・ヘッダー行を無視して証券コードのみ拾う")
    func extractsOnlyCodeRows() throws {
        let csv = """
            医薬品,,,,,,
            コード,銘柄名,社名,,,,
            4151,協和キリン,協和キリン（株）,,,,
            4502,武田,武田薬品工業（株）,,,,
            "電気機器
            ",,,,,,
            コード,銘柄名,社名,,,,
            285A,キオクシア,キオクシアホールディングス（株）,,,,
            """
        try withPriorityCSV(csv) { dir in
            let codes = loadPriorityIngestCodes(
                environment: [:], currentDirectoryPath: dir.path, executableURL: nil)
            #expect(codes == ["4151", "4502", "285A"])
        }
    }

    @Test("全角英数字はNFKC正規化・大文字化してから判定する")
    func normalizesFullWidthAndCase() throws {
        let csv = "２８５ａ,キオクシア,,,,,\n6501,日立,,,,,"
        try withPriorityCSV(csv) { dir in
            let codes = loadPriorityIngestCodes(
                environment: [:], currentDirectoryPath: dir.path, executableURL: nil)
            #expect(codes == ["285A", "6501"])
        }
    }

    @Test("4桁形式に一致しない先頭列は無視する")
    func ignoresNonCodeShapedFirstColumn() throws {
        let csv = """
            サービス,,,,,,
            コード,銘柄名,社名,,,,
            123,不完全なコード,,,,,
            12345,長すぎるコード,,,,,
            6501,日立,,,,,
            """
        try withPriorityCSV(csv) { dir in
            let codes = loadPriorityIngestCodes(
                environment: [:], currentDirectoryPath: dir.path, executableURL: nil)
            #expect(codes == ["6501"])
        }
    }

    @Test("ファイル未配置なら空集合（優先なしにフォールバック）")
    func returnsEmptySetWhenFileMissing() {
        let codes = loadPriorityIngestCodes(
            environment: [:], currentDirectoryPath: "/nonexistent-\(UUID().uuidString)",
            executableURL: nil, fileExists: { _ in false })
        #expect(codes.isEmpty)
    }
}
