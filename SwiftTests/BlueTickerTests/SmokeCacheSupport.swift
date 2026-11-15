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
// 実際に取得した docID は `XBRL_TIMING <docID> <source> wait=<秒> fetch=<秒>` も出す
// （wait = 同時実行枠の待ち、fetch = 取得と展開）。同じく golden-suite.sh が合計と最大を表示する。

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

/// 取得済みの docID が展開されているディレクトリを覚える。スイートごとに cacheDir が違っても
/// （`tmp_cache/edinet` と `~/.config/...` など）同じ書類を R2 から二重に取らず、手元でコピーする。
actor XbrlFetchedDirs {
    static let shared = XbrlFetchedDirs()
    private var dirs: [String: URL] = [:]

    func record(docID: String, dir: URL) {
        if dirs[docID] == nil { dirs[docID] = dir }
    }

    /// `excluding` 以外の cacheDir に展開済みの書類があればその cacheDir。
    func other(docID: String, excluding: URL) -> URL? {
        guard let dir = dirs[docID], dir.standardizedFileURL != excluding.standardizedFileURL else { return nil }
        return dir
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
    /// 1 書類 2.5 秒ほどの R2 GET が主なので、6 本では全スイートの待ちが 6 分を超えていた。
    private static let fetchSemaphore = AsyncSemaphore(value: 16)

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
        if store.hasXbrlDir(docID, saveDir: dir) {
            await XbrlFetchedDirs.shared.record(docID: docID, dir: dir)
            return "local"
        }
        if let other = await XbrlFetchedDirs.shared.other(docID: docID, excluding: dir),
           copyExtracted(docID: docID, from: other, to: dir)
        {
            await XbrlFetchedDirs.shared.record(docID: docID, dir: dir)
            return "local"
        }
        let queuedAt = ContinuousClock.now
        await fetchSemaphore.wait()
        defer { fetchSemaphore.signal() }
        let startedAt = ContinuousClock.now
        let objectStore = r2Config.map { ReadOnlyXbrlObjectStore(base: R2XbrlObjectStore(config: $0)) }
        let client = EdinetAPIClient(apiKey: apiKey, cacheStore: store, xbrlObjectStore: objectStore)
        let downloaded = await client.downloadDocument(docID, saveDir: dir) != nil
        let source: String
        if !downloaded {
            source = "failed"
        } else if let objectStore {
            if await objectStore.servedFromR2 {
                source = "r2"
            } else if await objectStore.missedR2 {
                source = "edinet"
            } else {
                // R2 に問い合わせずに返った = 別プロセスが展開済み（ファイルロック内でローカル判定）。
                source = "local"
            }
        } else {
            source = "edinet"
        }
        if source != "failed" { await XbrlFetchedDirs.shared.record(docID: docID, dir: dir) }
        let wait = seconds(startedAt - queuedAt)
        let fetch = seconds(ContinuousClock.now - startedAt)
        print("XBRL_TIMING \(docID) \(source) wait=\(wait) fetch=\(fetch)")
        return source
    }

    /// 別 cacheDir に展開済みの書類を一時ディレクトリへコピーしてから移す（途中で止まっても
    /// 完了マーカー付きの不完全なディレクトリを残さない）。失敗したら false で通常の取得に進む。
    private static func copyExtracted(docID: String, from src: URL, to dir: URL) -> Bool {
        let fm = FileManager.default
        let from = EdinetCacheStore(cacheDir: src).xbrlDir(docID, saveDir: src)
        let dest = EdinetCacheStore(cacheDir: dir).xbrlDir(docID, saveDir: dir)
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".copy-\(docID)-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: from, to: tmp)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
    }

    private static func seconds(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.2f", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }
}
