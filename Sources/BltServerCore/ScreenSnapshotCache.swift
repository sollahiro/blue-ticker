// `GET /v1/screen/snapshot` の作り置き。
//
// screen_index は財務 ingest でしか変わらないので、全行の読み取り・直列化・ETag 計算は
// リクエストごとにせず、起動時と `Api.screenSnapshotRebuildIntervalSeconds`（3 日）ごとに裏で行う。
// リクエストは作り置きの本文を返すだけ（304 の判定も作り置きの ETag で行う）。
// 起動直後で作り置きがまだ無いときだけ、そのリクエストで作って置く。
// 手元から Neon に ingest した直後に反映したいときはサーバーを再起動する。

import BltStoreCore
import BlueTickerCore
import Fluent
import Foundation
import Logging
import Vapor

/// 直列化済みの本文と強い ETag（本文の SHA-256）。
struct PreparedScreenSnapshot: Sendable, Equatable {
    let body: Data
    let etag: String
}

enum ScreenSnapshotBuildResult: Sendable, Equatable {
    case ready(PreparedScreenSnapshot)
    /// 索引が未生成（0 行）。
    case notFound
    /// DB 未接続・読み取り失敗・直列化失敗。
    case unavailable
}

/// 作り置きの置き場所。`registerRoutes` が `Application.storage` に 1 つ置く。
actor ScreenSnapshotCache {
    private var prepared: PreparedScreenSnapshot?

    func current() -> PreparedScreenSnapshot? { prepared }

    func store(_ snapshot: PreparedScreenSnapshot?) {
        prepared = snapshot
    }
}

struct ScreenSnapshotCacheKey: StorageKey {
    typealias Value = ScreenSnapshotCache
}

/// 直列化（`.sortedKeys`。同じ中身なら同じバイト列）して ETag を付ける。
func prepareScreenSnapshot(_ body: [String: Any]) -> PreparedScreenSnapshot? {
    guard JSONSerialization.isValidJSONObject(body),
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    else { return nil }
    let etag = "\"" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\""
    return PreparedScreenSnapshot(body: data, etag: etag)
}

/// screen_index 全行を読んで作り置きの形にする。
func buildScreenSnapshot(db: Database?, logger: Logger) async -> ScreenSnapshotBuildResult {
    switch await serveScreenSnapshot(db: db, logger: logger) {
    case .ok(let body):
        guard let prepared = prepareScreenSnapshot(body) else { return .unavailable }
        return .ready(prepared)
    case .notFound:
        return .notFound
    case .dbUnavailable:
        return .unavailable
    }
}

/// 1 回分の作り直し。成功は差し替え、未生成は空にする（404 に戻す）。DB 失敗は前の作り置きを残す。
/// 戻り値は作り置きを差し替えられたか（呼び出し側の次回までの待ち時間を決める）。
@discardableResult
func refreshScreenSnapshot(cache: ScreenSnapshotCache, db: Database, logger: Logger) async -> Bool {
    switch await buildScreenSnapshot(db: db, logger: logger) {
    case .ready(let prepared):
        await cache.store(prepared)
        logger.notice("screen snapshot を作り直しました（\(prepared.body.count) bytes, etag=\(prepared.etag)）")
        return true
    case .notFound:
        await cache.store(nil)
        return false
    case .unavailable:
        logger.warning("screen snapshot の作り直しに失敗しました（前の作り置きを使い続けます）")
        return false
    }
}

/// サーバー起動時に作り直しループを始める（DATABASE_URL 設定時のみ呼び出し側が呼ぶ。`registerRoutes` の後）。
/// 成功後は 3 日待つ。未生成・失敗は `Api.screenSnapshotRetryIntervalSeconds` で再試行する。
func startScreenSnapshotRefresh(app: Application) {
    guard let cache = app.storage[ScreenSnapshotCacheKey.self] else { return }
    let db = app.db
    let logger = app.logger
    Task.detached {
        while !Task.isCancelled {
            let refreshed = await refreshScreenSnapshot(cache: cache, db: db, logger: logger)
            let wait =
                refreshed ? Api.screenSnapshotRebuildIntervalSeconds : Api.screenSnapshotRetryIntervalSeconds
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
    }
}
