// EDINET マスタデータ（コードリスト CSV）の Neon 反映。
// 正本は Neon の edinet_master_snapshot（単一行）。手動アップロードで正本を更新し、
// 定期ポーリングでサーバーのローカルファイルへ反映する（デプロイ不要で更新可能にする）。
// DB 行が無い場合はイメージに焼き込まれた既存 CSV をそのまま使う（フォールバック、無停止移行）。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation

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

/// `blt-ingest master-data-upload <path>` の本体。ローカル CSV を Neon へ丸ごと反映する（単一行 upsert）。
public func runMasterDataUploadCommand(path: String) async throws {
    guard let urlString = bltEnvironmentValue("DATABASE_URL"), !urlString.isEmpty else {
        throw MasterDataError.databaseUnavailable
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        throw MasterDataError.fileNotFound(path)
    }

    let app = try BltCommandDatabase.connect(urlString: urlString, label: "blt-ingest")
    do {
        try await migrateBltSchema(app)
        try await upsertMasterDataSnapshot(data, db: app.db, logger: app.logger)
        app.logger.notice("EDINET マスタデータを Neon へ反映しました（\(data.count) bytes）。")
    } catch {
        await app.asyncShutdown()
        throw error
    }
    await app.asyncShutdown()
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

