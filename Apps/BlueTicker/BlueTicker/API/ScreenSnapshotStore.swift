import Foundation

/// 条件検索のスナップショット（`ScreenSnapshot`、`GET /v1/screen/snapshot`）の端末保存と条件付き GET。
/// 生の本文と `ETag` / 取得時刻を Caches に 1 ファイルで持つ（置き場所は `FeedRSSStore` にそろえる）。
/// 前回の取得から `ScreenSnapshot.revalidateInterval` 以内は再検証しない。
/// 304 は取得時刻だけ進め、200 は保存を差し替える。失敗しても保存は消さない。
/// 保存も取得もできないときは呼び出し側が REST `GET /v1/screen` に戻す。
actor ScreenSnapshotStore {
    static let shared = ScreenSnapshotStore()

    private let fileURL: URL
    private let fileDecoder: JSONDecoder
    private let fileEncoder: JSONEncoder
    private var record: ScreenSnapshot.Record?
    private var rows: [ScreenSnapshot.Row]?
    private var restored = false
    private var inFlight: Task<[ScreenSnapshot.Row]?, Never>?

    init(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = caches
                .appendingPathComponent("blt-screen", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
        fileURL = base.appendingPathComponent("screen-snapshot.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        fileDecoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        fileEncoder = encoder
    }

    /// 保存済みのスナップショット（通信しない）。保存が無い・読めなければ `nil`。
    /// 読めない保存は検証子ごと忘れ、次の再検証を全件取得にする。
    func cachedRows() -> [ScreenSnapshot.Row]? {
        if let rows { return rows }
        guard let record = restoredRecord() else { return nil }
        guard let parsed = ScreenSnapshot.parse(record.body) else {
            self.record = nil
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        rows = parsed
        return parsed
    }

    func needsRevalidation(now: Date = Date()) -> Bool {
        ScreenSnapshot.needsRevalidation(restoredRecord(), now: now)
    }

    /// 条件付き GET を送る。200 で解析できたときだけ新しい行を返す（304・失敗・cancel は `nil`）。
    /// 同時の呼び出し（件数と結果画面）は 1 本にまとめる。
    func revalidate(now: Date = Date()) async -> [ScreenSnapshot.Row]? {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.fetch(now: now) }
        inFlight = task
        let fresh = await task.value
        inFlight = nil
        return fresh
    }

    /// 保存があればそれを、無ければ取得して返す。どちらも無理なら `nil`。
    func rowsFetchingIfNeeded() async -> [ScreenSnapshot.Row]? {
        if let cached = cachedRows() { return cached }
        _ = await revalidate()
        return cachedRows()
    }

    private func fetch(now: Date) async -> [ScreenSnapshot.Row]? {
        let previous = restoredRecord()
        let response: (status: Int, etag: String?, body: Data)
        do {
            response = try await APIClient.shared.screenSnapshot(
                headers: ScreenSnapshot.requestHeaders(for: previous))
        } catch {
            return nil
        }
        let outcome = ScreenSnapshot.outcome(
            status: response.status, etag: response.etag, body: response.body,
            previous: previous, now: now)
        switch outcome {
        case .notModified(let updated):
            save(updated)
            return nil
        case .replaced(let updated, let parsed):
            save(updated)
            rows = parsed
            return parsed
        case .failed:
            return nil
        }
    }

    private func restoredRecord() -> ScreenSnapshot.Record? {
        if !restored {
            restored = true
            if let raw = try? Data(contentsOf: fileURL) {
                record = try? fileDecoder.decode(ScreenSnapshot.Record.self, from: raw)
            }
        }
        return record
    }

    private func save(_ updated: ScreenSnapshot.Record) {
        record = updated
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileEncoder.encode(updated).write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}

extension ScreenPreset {
    /// プリセットを端末内で引く。条件・並びは `GET /v1/screen` に載せるものと同じ。
    func search(
        _ rows: [ScreenSnapshot.Row], sectors: [String], limit: Int? = nil
    ) -> ScreenSnapshot.Result {
        ScreenSnapshot.search(
            rows, sectors: sectors,
            filters: filters.map { ScreenSnapshot.Filter(key: $0.key, min: $0.min, max: $0.max) },
            sort: sortMetric, limit: limit)
    }
}

extension ScreenItem {
    init(_ row: ScreenSnapshot.Row) {
        self.init(
            code: row.code, name: row.name, market: row.market, sector: row.sector,
            periodEnd: row.periodEnd, sales: row["sales"],
            operatingMargin: row["operating_margin"], roic: row["roic"], roe: row["roe"],
            netDe: row["net_de"], salesCagr3y: row["sales_cagr_3y"], cfoMargin: row["cfo_margin"],
            fcf: row["fcf"], operatingMarginCagr3y: row["operating_margin_cagr_3y"],
            roicCagr3y: row["roic_cagr_3y"], payoutRatio: row["payout_ratio"],
            payoutRatio3y: row.payoutRatio3y)
    }
}
