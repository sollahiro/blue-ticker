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

    /// `cacheDir` 省略時は `tmp_cache/edinet`（従来通り）。`RealXbrlBreakdown*Tests` のような
    /// 別ディレクトリ（`~/.config/blue-ticker/analysis_cache/...`）を使う呼び出し元は明示指定する。
    static func ensureCached(_ docIDs: some Sequence<String>, cacheDir: URL? = nil) async {
        guard let apiKey = ProcessInfo.processInfo.environment["BLT_EDINET_API_KEY"], !apiKey.isEmpty else {
            return
        }
        let dir = cacheDir ?? self.cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EdinetCacheStore(cacheDir: dir)
        let client = EdinetAPIClient(apiKey: apiKey, cacheStore: store)

        for docID in docIDs {
            // hasXbrlDir の事前判定は行わない。展開途中ディレクトリとの race を避け、
            // downloadDocument 側のファイルロック内で完了済みか判定させる。
            if await client.downloadDocument(docID, saveDir: dir) == nil {
                print("FAIL   \(docID): ダウンロード失敗")
            }
        }
    }
}
