// スモークテスト用 XBRL キャッシュ（tmp_cache/edinet/）の自動取得ユーティリティ。
//
// BLT_EDINET_API_KEY 環境変数（blt-server と共通）が設定されている場合のみ、
// 不足している docID を EDINET からダウンロードする。未設定の場合は何もせず、
// 呼び出し側（各スモークテスト）が既存のキャッシュ有無で SKIP 判定する。

import Foundation
@testable import BlueTickerCore

enum SmokeCacheSupport {
    static let cacheDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp_cache/edinet")

    static func ensureCached(_ docIDs: some Sequence<String>) async {
        guard let apiKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"], !apiKey.isEmpty else {
            return
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let store = EdinetCacheStore(cacheDir: cacheDir)
        let client = EdinetAPIClient(apiKey: apiKey, cacheStore: store)

        for docID in docIDs {
            guard !store.hasXbrlDir(docID, saveDir: cacheDir) else { continue }
            if await client.downloadDocument(docID, saveDir: cacheDir) == nil {
                print("FAIL   \(docID): ダウンロード失敗")
            }
        }
    }
}
