// スモークテスト用 XBRL キャッシュ（tmp_cache/edinet/）の準備ユーティリティ。
// 旧 smoke/prepare_cache.py / prepare_half_cache.py の置き換え。
//
// 通常のテスト実行では無効。環境変数を付けて手動実行する:
//
//     SMOKE_PREPARE=1 swift test --filter SmokeCachePrepare
//
// 対象書類は smoke/segment_expected.json のキー（docID）を正とする。
// 年次・半期スモークの全 docID を含み、ゴールデンファイルと参照先がずれない。
// ダウンロード済みの書類はスキップされる（EdinetAPIClient のキャッシュ判定）。
// EDINET API キーは SettingsStore（Keychain / secrets.json）から読む。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct SmokeCachePrepare {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SMOKE_PREPARE"] == "1"))
    func prepareSmokeCache() async throws {
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // BlueTickerTests
            .deletingLastPathComponent()  // SwiftTests
            .deletingLastPathComponent()  // project root
        let cacheDir = projectRoot.appendingPathComponent("tmp_cache/edinet")
        let goldenPath = projectRoot.appendingPathComponent("smoke/segment_expected.json")

        let data = try Data(contentsOf: goldenPath)
        let golden = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let docIDs = golden.keys.sorted()

        let apiKey = await settingsStore.get(.edinetApiKey)
        try #require(apiKey?.isEmpty == false, "EDINET API キーが設定されていません（ticker config set edinet-key <key>）")

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let store = EdinetCacheStore(cacheDir: cacheDir)
        let client = EdinetAPIClient(apiKey: apiKey, cacheStore: store)

        var failed: [String] = []
        for docID in docIDs {
            if store.hasXbrlDir(docID, saveDir: cacheDir) {
                print("SKIP   \(docID): 展開済み")
                continue
            }
            if let dir = await client.downloadDocument(docID, saveDir: cacheDir) {
                print("OK     \(docID): \(dir.path)")
            } else {
                print("FAIL   \(docID): ダウンロード失敗")
                failed.append(docID)
            }
        }
        #expect(failed.isEmpty, Comment(rawValue: "ダウンロード失敗: \(failed.joined(separator: ", "))"))
    }
}
