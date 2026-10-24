import BlueTickerCore
import BltStoreCore
import Fluent
import Foundation
import Vapor

/// `edinet_master_snapshot` と同一テーブルを指すが `updated_at` のみ宣言する射影モデル。
/// ポーリングでの変更検知用（Fluent の SELECT は宣言済みフィールドのみを対象にするため、
/// 変更が無ければ 2.3MB の `content` を毎回転送せずに済む）。
final class EdinetMasterSnapshotUpdatedAt: Model, @unchecked Sendable {
    static let schema = EdinetMasterSnapshot.schema

    @ID(custom: "id", generatedBy: .user)
    var id: Int?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

/// Neon の edinet_master_snapshot を定期ポーリングし、更新されていればローカルへ反映する。
/// updated_at の変化のみで検知する。変更が無ければ軽量な単発 find（updated_at のみ SELECT）で
/// 済み、`content`（CSV 本体、約 2.3MB）は変更検知後にのみ取得する。
actor MasterDataRefresher {
    private var lastAppliedUpdatedAt: Date?

    func pollOnce(db: Database, logger: Logger?) async {
        let latestUpdatedAt: Date?
        do {
            latestUpdatedAt = try await withDbRetry(logger: logger) {
                try await EdinetMasterSnapshotUpdatedAt.find(EdinetMasterSnapshot.singletonID, on: db)
            }?.updatedAt
        } catch {
            logger?.warning("EDINET マスタデータのポーリングに失敗しました: \(error)")
            return
        }
        guard let updatedAt = latestUpdatedAt, updatedAt != lastAppliedUpdatedAt else { return }

        let found: EdinetMasterSnapshot?
        do {
            found = try await withDbRetry(logger: logger) {
                try await EdinetMasterSnapshot.find(EdinetMasterSnapshot.singletonID, on: db)
            }
        } catch {
            logger?.warning("EDINET マスタデータの取得に失敗しました: \(error)")
            return
        }
        guard let snapshot = found else { return }

        guard await applyEdinetMasterDataSnapshot(snapshot.content) else {
            logger?.warning("EDINET マスタデータの反映に失敗しました（パス未解決または書き込み失敗）。")
            return
        }
        // 実際に適用した本体 find の updated_at を記録する（軽量 find との間で行が更新される
        // 競合窓を避ける。万一 nil ならフォールバックとして軽量 find の値を使う）。
        lastAppliedUpdatedAt = snapshot.updatedAt ?? updatedAt
        logger?.notice("EDINET マスタデータを Neon から反映しました（updated_at=\(snapshot.updatedAt ?? updatedAt)）。")
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
