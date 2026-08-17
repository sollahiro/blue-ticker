// 生 XBRL R2 L2 の実バケット検証。CI では走らない（`BLT_R2_XBRL_LIVE_TEST=1` が必要）。
// smoke 固定11社の最新有報 ZIP について、本番と同じ EdinetAPIClient 経路で
// ローカル L1 ミス → R2 GET（ミスなら EDINET GET + R2 PUT）→ L1 削除 → API キー無し R2 GET
// を確認し、展開ディレクトリを `tmp_cache/edinet` へ残す（後続の SmokeTests 用）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct R2XbrlLiveSmokeTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["BLT_R2_XBRL_LIVE_TEST"] == "1"
            && R2StorageConfig.resolveXbrlFromEnvironment() != nil
    }

    @Test(
        .enabled(if: liveEnabled, "BLT_R2_XBRL_LIVE_TEST=1 and R2 XBRL creds required"),
        .timeLimit(.minutes(30))
    )
    func seedAndReloadSmokeDocsFromR2() async throws {
        let apiKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"]
        let config = try #require(R2StorageConfig.resolveXbrlFromEnvironment())
        if let iconsBucket = R2StorageConfig.resolveIconsFromEnvironment()?.bucket {
            #expect(iconsBucket != config.bucket)
        }

        let fm = FileManager.default
        let workDir = try ServiceTestSupport.makeTempDir()
        defer { try? fm.removeItem(at: workDir) }
        let smokeDir = SmokeCacheSupport.cacheDir
        try fm.createDirectory(at: smokeDir, withIntermediateDirectories: true)

        let store = EdinetCacheStore(cacheDir: workDir)
        let objectStore = R2XbrlObjectStore(config: config)
        let r2Only = EdinetAPIClient(
            apiKey: nil, cacheStore: store, xbrlObjectStore: objectStore)
        let withRemote = EdinetAPIClient(
            apiKey: apiKey, cacheStore: store, xbrlObjectStore: objectStore)

        var failures: [String] = []
        var logLines: [String] = [
            "bucket=\(config.bucket) prefix=\(Api.xbrlR2KeyPrefix)/"
        ]

        for (code, docID, name) in BreakdownSmokeOracleSupport.smokeDocs {
            let started = Date()
            try? fm.removeItem(at: store.xbrlDir(docID, saveDir: workDir))

            var source = "R2_HIT"
            var dir = await r2Only.downloadDocument(docID, saveDir: workDir)
            if dir == nil {
                source = "EDINET_PUT"
                dir = await withRemote.downloadDocument(docID, saveDir: workDir)
                guard dir != nil else {
                    let msg = "\(code) \(name) \(docID): EDINET/R2 取得失敗"
                    failures.append(msg)
                    logLines.append("FAIL \(msg)")
                    continue
                }
                try? fm.removeItem(at: store.xbrlDir(docID, saveDir: workDir))
                dir = await r2Only.downloadDocument(docID, saveDir: workDir)
            }

            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            guard let dir, store.hasXbrlDir(docID, saveDir: workDir) else {
                let msg = "\(code) \(name) \(docID): R2 GET 失敗 source=\(source)"
                failures.append(msg)
                logLines.append("FAIL \(msg) elapsed_ms=\(elapsedMs)")
                continue
            }

            let xbrlFiles = XBRLUtils.findXbrlFiles(in: dir)
            if xbrlFiles.isEmpty {
                let msg = "\(code) \(name) \(docID): 展開後に .xbrl/.xml が無い"
                failures.append(msg)
                logLines.append("FAIL \(msg)")
                continue
            }

            let dest = smokeDir.appendingPathComponent("\(docID)_xbrl")
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: dir, to: dest)

            let line =
                "OK \(code) \(name) \(docID) source=\(source) xbrl_files=\(xbrlFiles.count) elapsed_ms=\(elapsedMs)"
            print(line)
            logLines.append(line)
        }

        print(logLines.joined(separator: "\n"))
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
        #expect(logLines.contains(where: { $0.hasPrefix("OK ") }))
    }
}
