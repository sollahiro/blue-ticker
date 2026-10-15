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
import Testing
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

/// 同一プロセス内で同じ (cacheDir, docID) の取得を 1 本にまとめる（single-flight）。
/// 後から来た呼び出しは先行タスクの結果を待つ。ファイルロックのポーリング（3 分で timeout）に
/// 頼らないので、遅い取得の裏で待機側が諦めて nil を返す race が起きない。
actor XbrlFetchSingleFlight {
    static let shared = XbrlFetchSingleFlight()
    private var inFlight: [String: Task<String, Never>] = [:]

    func run(key: String, _ work: @escaping @Sendable () async -> String) async -> (source: String, joined: Bool) {
        if let task = inFlight[key] {
            return (await task.value, true)
        }
        let task = Task { await work() }
        inFlight[key] = task
        let source = await task.value
        inFlight[key] = nil
        return (source, false)
    }
}

enum SmokeCacheSupport {
    static let cacheDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp_cache/edinet")

    /// CI の golden-suite（`BLT_GOLDEN_STRICT=1`）では取得できない書類をテスト失敗にする。
    /// ローカルで未設定なら従来通り SKIP（呼び出し側がキャッシュ有無で判定）。
    static var isStrict: Bool {
        ProcessInfo.processInfo.environment["BLT_GOLDEN_STRICT"] == "1"
    }

    /// 取得の同時実行数。全スイートが一斉に要求しても各取得が短時間で終わるよう絞る。
    private static let fetchSemaphore = AsyncSemaphore(value: 6)

    /// `cacheDir` 省略時は `tmp_cache/edinet`（従来通り）。`RealXbrlBreakdown*Tests` のような
    /// 別ディレクトリ（`~/.config/blue-ticker/analysis_cache/...`）を使う呼び出し元は明示指定する。
    static func ensureCached(_ docIDs: some Sequence<String>, cacheDir: URL? = nil) async {
        let env = ProcessInfo.processInfo.environment
        let apiKey = env["BLT_EDINET_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        let r2Config = R2StorageConfig.resolveXbrlFromEnvironment(env)
        guard apiKey != nil || r2Config != nil else {
            if isStrict {
                Issue.record("BLT_GOLDEN_STRICT=1 but neither R2 XBRL credentials nor BLT_EDINET_API_KEY is set")
            }
            return
        }

        let dir = cacheDir ?? self.cacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for docID in docIDs {
            let key = dir.standardizedFileURL.path + "|" + docID
            let (source, joined) = await XbrlFetchSingleFlight.shared.run(key: key) {
                await fetch(docID: docID, dir: dir, apiKey: apiKey, r2Config: r2Config)
            }
            // 合流した呼び出しは取得していないので local と数える（失敗はそのまま失敗）。
            let reported = joined && source != "failed" ? "local" : source
            print("XBRL_SOURCE \(docID) \(reported)")
            if source == "failed" {
                print("FAIL   \(docID): ダウンロード失敗")
                if isStrict {
                    Issue.record("BLT_GOLDEN_STRICT=1: XBRL \(docID) を R2 / EDINET から取得できませんでした")
                }
            }
        }
    }

    private static func fetch(
        docID: String, dir: URL, apiKey: String?, r2Config: R2StorageConfig?
    ) async -> String {
        let store = EdinetCacheStore(cacheDir: dir)
        if store.hasXbrlDir(docID, saveDir: dir) { return "local" }
        await fetchSemaphore.wait()
        defer { fetchSemaphore.signal() }
        let objectStore = r2Config.map { ReadOnlyXbrlObjectStore(base: R2XbrlObjectStore(config: $0)) }
        let client = EdinetAPIClient(apiKey: apiKey, cacheStore: store, xbrlObjectStore: objectStore)
        guard await client.downloadDocument(docID, saveDir: dir) != nil else { return "failed" }
        guard let objectStore else { return "edinet" }
        if await objectStore.servedFromR2 { return "r2" }
        if await objectStore.missedR2 { return "edinet" }
        // R2 に問い合わせずに返った = 別プロセスが展開済み（ファイルロック内でローカル判定）。
        return "local"
    }
}
