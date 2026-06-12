// サービス層テスト共通ヘルパー
// Python tests/test_edinet_* / test_cache_pruner の tmp_path・os.utime・zip 生成相当

import Foundation
import ZIPFoundation
@testable import BlueTickerCore

enum ServiceTestSupport {

    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// UTC の今日（0時）
    static func utcToday() -> Date {
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: Date())
        return utcCalendar.date(from: comps)!
    }

    static func addDays(_ date: Date, _ days: Int) -> Date {
        utcCalendar.date(byAdding: .day, value: days, to: date)!
    }

    static func iso(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func currentUTCYear() -> Int {
        utcCalendar.component(.year, from: Date())
    }

    /// テストごとの一時ディレクトリを作る（pytest tmp_path 相当）
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// mtime を指定日数前に設定する（os.utime 相当）。
    /// Calendar の日数差計算の境界ゆらぎを避けるため 1 時間のマージンを足す。
    static func age(_ url: URL, days: Int) throws {
        let ts = Date().addingTimeInterval(-(Double(days) * 86_400 + 3_600))
        try setMtime(url, ts)
    }

    static func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    static func mtime(_ url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }

    /// 指定ファイル群を含む ZIP データを生成する（_make_xbrl_zip 相当）
    static func makeXbrlZip(files: [String: String]) throws -> Data {
        let fm = FileManager.default
        let workDir = try makeTempDir()
        defer { try? fm.removeItem(at: workDir) }
        let srcDir = workDir.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: srcDir.appendingPathComponent(name))
        }
        let zipURL = workDir.appendingPathComponent("out.zip")
        try fm.zipItem(at: srcDir, to: zipURL, shouldKeepParent: false)
        return try Data(contentsOf: zipURL)
    }
}
