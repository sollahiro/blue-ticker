// スモーク／ゴールデンテスト用 XBRL キャッシュの自動取得ユーティリティ。
//
// 取得順: ローカル展開済み → R2（読み取り専用）→ EDINET。
// - R2: `BLT_R2_ACCOUNT_ID` / `BLT_R2_ACCESS_KEY_ID` / `BLT_R2_SECRET_ACCESS_KEY` /
//   `BLT_R2_XBRL_BUCKET` が揃っているときだけ GET する。PUT（書き戻し）は一切しない。
// - EDINET: `BLT_EDINET_API_KEY` があるときだけ。R2 に無い docID のフォールバック。
// どちらも未設定（fork からの PR 等）なら何もせず、呼び出し側が SKIP 判定する。
//
// docID ごとに `XBRL_SOURCE <docID> <local|r2|edinet|failed>` を出力する。
// scripts/ci/golden-suite.sh がこの行を集計して run ごとの内訳を表示する。

import Foundation
@testable import BlueTickerCore

/// R2 から読むだけのストア。`putObject` は何もせず false を返す（CI は本番バケットへ書かない）。
/// 1 docID ごとに作り、R2 から取れたかを記録する。
actor ReadOnlyXbrlObjectStore: XbrlObjectStoring {
    private let base: any XbrlObjectStoring
    private(set) var servedFromR2 = false
    /// GET したが R2 に無かった（この後 EDINET へ進む）。
    private(set) var missedR2 = false

    init(base: any XbrlObjectStoring) {
        self.base = base
    }

    func getObject(key: String) async -> Data? {
        let data = await base.getObject(key: key)
        if data != nil { servedFromR2 = true } else { missedR2 = true }
        return data
    }

    func putObject(_ data: Data, key: String, contentType: String) async -> Bool {
        false
    }
}

enum SmokeCacheSupport {
    static let cacheDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp_cache/edinet")

    /// `cacheDir` 省略時は `tmp_cache/edinet`（従来通り）。`RealXbrlBreakdown*Tests` のような
    /// 別ディレクトリ（`~/.config/blue-ticker/analysis_cache/...`）を使う呼び出し元は明示指定する。
    static func ensureCached(_ docIDs: some Sequence<String>, cacheDir: URL? = nil) async {
        let env = ProcessInfo.processInfo.environment
        let apiKey = env["BLT_EDINET_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        let r2Config = R2StorageConfig.resolveXbrlFromEnvironment(env)
        guard apiKey != nil || r2Config != nil else { return }

        let dir = cacheDir ?? self.cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EdinetCacheStore(cacheDir: dir)

        for docID in docIDs {
            if store.hasXbrlDir(docID, saveDir: dir) {
                print("XBRL_SOURCE \(docID) local")
                continue
            }
            let objectStore = r2Config.map { ReadOnlyXbrlObjectStore(base: R2XbrlObjectStore(config: $0)) }
            let client = EdinetAPIClient(
                apiKey: apiKey, cacheStore: store, xbrlObjectStore: objectStore)
            // hasXbrlDir の事前判定は計数用。取得自体は downloadDocument 側のファイルロック内で
            // 完了済みか判定させる（展開途中ディレクトリとの race を避ける）。
            let result = await client.downloadDocument(docID, saveDir: dir)
            let source: String
            if result == nil {
                source = "failed"
                print("FAIL   \(docID): ダウンロード失敗")
            } else if let objectStore {
                // R2 に問い合わせずに返った = 別スイートが同時に展開済み（ロック内でローカル判定）。
                if await objectStore.servedFromR2 {
                    source = "r2"
                } else if await objectStore.missedR2 {
                    source = "edinet"
                } else {
                    source = "local"
                }
            } else {
                source = "edinet"
            }
            print("XBRL_SOURCE \(docID) \(source)")
        }
    }
}
