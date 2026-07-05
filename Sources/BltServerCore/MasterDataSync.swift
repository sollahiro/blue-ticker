// EDINET マスタデータ（コードリスト CSV）の Neon 反映。
// 正本は Neon の edinet_master_snapshot（単一行）。手動アップロードで正本を更新し、
// 定期ポーリングでサーバーのローカルファイルへ反映する（デプロイ不要で更新可能にする）。
// DB 行が無い場合はイメージに焼き込まれた既存 CSV をそのまま使う（フォールバック、無停止移行）。

import BlueTickerCore
import Fluent
import Foundation
import Vapor

enum MasterDataError: Error, CustomStringConvertible {
    case databaseUnavailable
    case fileNotFound(String)

    var description: String {
        switch self {
        case .databaseUnavailable:
            return "DATABASE_URL が未設定です。master-data-upload には DB 接続が必要です。"
        case .fileNotFound(let path):
            return "指定されたファイルが見つかりません: \(path)"
        }
    }
}

// MARK: - CLI エントリ（アップロード）

/// `blt-server master-data-upload <path>` の本体。ローカル CSV を Neon へ丸ごと反映する（単一行 upsert）。
public func runMasterDataUploadCommand(path: String) async throws {
    guard let urlString = Environment.get("DATABASE_URL"), !urlString.isEmpty else {
        throw MasterDataError.databaseUnavailable
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        throw MasterDataError.fileNotFound(path)
    }

    var env = Environment(name: "production", arguments: ["blt-server"])
    try LoggingSystem.bootstrap(from: &env)
    let app = try await Application.make(env)
    do {
        try await configureDatabase(app)
        try await upsertMasterDataSnapshot(data, db: app.db, logger: app.logger)
        app.logger.notice("EDINET マスタデータを Neon へ反映しました（\(data.count) bytes）。")
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// edinet_master_snapshot（単一行）を upsert する。
func upsertMasterDataSnapshot(_ data: Data, db: Database, logger: Logger? = nil) async throws {
    let snapshot = try await withDbRetry(logger: logger) {
        try await EdinetMasterSnapshot.find(EdinetMasterSnapshot.singletonID, on: db)
    } ?? EdinetMasterSnapshot()
    snapshot.id = EdinetMasterSnapshot.singletonID
    snapshot.content = data
    try await withDbRetry(logger: logger) { try await snapshot.save(on: db) }
}

// MARK: - 定期ポーリング（サーバー起動中の反映）

/// Neon の edinet_master_snapshot を定期ポーリングし、更新されていればローカルへ反映する。
/// updated_at の変化のみで検知するため、変更が無ければ軽量な単発 find のみで済む。
actor MasterDataRefresher {
    private var lastAppliedUpdatedAt: Date?

    func pollOnce(db: Database, logger: Logger?) async {
        let found: EdinetMasterSnapshot?
        do {
            found = try await withDbRetry(logger: logger) {
                try await EdinetMasterSnapshot.find(EdinetMasterSnapshot.singletonID, on: db)
            }
        } catch {
            logger?.warning("EDINET マスタデータのポーリングに失敗しました: \(error)")
            return
        }
        guard let snapshot = found, let updatedAt = snapshot.updatedAt else { return }
        guard updatedAt != lastAppliedUpdatedAt else { return }

        guard await applyEdinetMasterDataSnapshot(snapshot.content) else {
            logger?.warning("EDINET マスタデータの反映に失敗しました（パス未解決または書き込み失敗）。")
            return
        }
        lastAppliedUpdatedAt = updatedAt
        logger?.notice("EDINET マスタデータを Neon から反映しました（updated_at=\(updatedAt)）。")
    }
}

/// サーバー起動時にポーリングループを開始する（DATABASE_URL 設定時のみ呼び出し側が呼ぶ）。
func startMasterDataPolling(app: Application) {
    let refresher = MasterDataRefresher()
    let db = app.db
    let logger = app.logger
    Task.detached {
        while !Task.isCancelled {
            await refresher.pollOnce(db: db, logger: logger)
            try? await Task.sleep(nanoseconds: Api.masterDataPollIntervalSeconds * 1_000_000_000)
        }
    }
}
