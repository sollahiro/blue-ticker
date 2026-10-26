import Foundation

/// 条件検索の取得元。`GET /v1/screen/snapshot`（`screen_index` 全行の列形式）を 1 回取り、
/// 件数・絞り込み・並べ替えを端末内で行う。`screen_index` は財務 ingest でしか変わらず、サーバーも
/// 3 日ごとにしか作り直さないので、
/// 保存した本文を `ETag` の条件付き GET で取り直す（`revalidateInterval` 以内は再検証しない）。
/// 検索の意味は REST `GET /v1/screen` と同じ（業種は完全一致の OR、範囲は両端含む AND、
/// フィルタ・ソート対象が null の行は落とす、同値はコード昇順）。
enum ScreenSnapshot {
    /// 応答の形の版（サーバー `screenSnapshotSchemaVersion`）。違う版は解析しない。
    /// v2: 金額指標（sales / cfo / fcf）が百万円から円になった。
    static let schemaVersion = 2
    /// 前回の取得からこの間は再検証しない（3 日。サーバーの作り直し間隔
    /// `Api.screenSnapshotRebuildIntervalSeconds` と同じ）。
    static let revalidateInterval: TimeInterval = 3 * 24 * 60 * 60

    /// 1 社の最新 FY。`metrics` のキーは REST の指標名（`roic` など）。null は持たない。
    struct Row: Hashable, Sendable {
        var code: String
        var name: String
        var market: String
        var sector: String
        var periodEnd: String
        var metrics: [String: Double]
        /// 直近 3 期の年次配当性向（古→新）。長さは常に 3。
        var payoutRatio3y: [Double?]

        subscript(_ key: String) -> Double? { metrics[key] }
    }

    /// 1 指標の範囲（両端含む。片側のみ可）。
    struct Filter: Hashable, Sendable {
        var key: String
        var min: Double?
        var max: Double?

        init(key: String, min: Double?, max: Double?) {
            self.key = key
            self.min = min
            self.max = max
        }
    }

    struct Result: Equatable, Sendable {
        /// 上限前の件数（REST の `matched`）。
        var matched: Int
        var rows: [Row]
    }

    /// 端末に保存する本文と検証子と取得時刻。
    struct Record: Codable, Equatable, Sendable {
        var body: Data
        var etag: String?
        var fetchedAt: Date
    }

    enum Outcome: Equatable, Sendable {
        /// 304。保存済みの本文を使い続け、取得時刻（と届いた検証子）だけ進める。
        case notModified(Record)
        /// 200 で解析できた。保存を差し替える。
        case replaced(Record, [Row])
        /// HTTP・解析の失敗。保存済みの分を使い続ける。
        case failed
    }

    /// REST `GET /v1/screen` と同じ規則で絞り込み、`sort` で並べて先頭 `limit` 件を返す。
    /// 業種が空なら全業種。`sort` が null の行も落とす（暗黙の絞り込み。REST と同じ）。
    static func search(
        _ rows: [Row], sectors: [String], filters: [Filter], sort: String,
        descending: Bool = true, limit: Int? = nil
    ) -> Result {
        let sectorSet = Set(sectors)
        var matched = rows.filter { row in
            if !sectorSet.isEmpty, !sectorSet.contains(row.sector) { return false }
            guard row[sort] != nil else { return false }
            for filter in filters {
                guard let value = row[filter.key] else { return false }
                if let min = filter.min, value < min { return false }
                if let max = filter.max, value > max { return false }
            }
            return true
        }
        matched.sort { lhs, rhs in
            let left = lhs[sort] ?? 0
            let right = rhs[sort] ?? 0
            if left != right { return descending ? left > right : left < right }
            return lhs.code < rhs.code
        }
        let count = matched.count
        if let limit, limit >= 0, matched.count > limit {
            matched.removeSubrange(limit...)
        }
        return Result(matched: count, rows: matched)
    }

    /// 保存が無い、または前回の取得から `revalidateInterval` 以上経っていれば再検証する。
    /// 端末の時計が戻って取得時刻が未来になったときも再検証する。
    static func needsRevalidation(_ record: Record?, now: Date) -> Bool {
        guard let record else { return true }
        let age = now.timeIntervalSince(record.fetchedAt)
        return age < 0 || age >= revalidateInterval
    }

    /// 条件付き GET のヘッダ。保存が無ければ検証子を付けない（全件取得）。
    static func requestHeaders(for record: Record?) -> [String: String] {
        guard let etag = record?.etag, !etag.isEmpty else { return [:] }
        return ["If-None-Match": etag]
    }

    static func outcome(
        status: Int, etag: String?, body: Data, previous: Record?, now: Date
    ) -> Outcome {
        switch status {
        case 304:
            guard var record = previous else { return .failed }
            record.fetchedAt = now
            if let etag, !etag.isEmpty { record.etag = etag }
            return .notModified(record)
        case 200..<300:
            guard let rows = parse(body) else { return .failed }
            return .replaced(Record(body: body, etag: etag, fetchedAt: now), rows)
        default:
            return .failed
        }
    }

    /// 列形式の本文を行へ戻す。版違い・列の長さの不一致・`count` との不一致は `nil`
    /// （途中で切れた本文や形の変わった応答で保存を差し替えない）。
    static func parse(_ data: Data) -> [Row]? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
            wire.schemaVersion == schemaVersion
        else { return nil }
        let count = wire.count
        guard wire.code.count == count, wire.name.count == count, wire.market.count == count,
            wire.sector.count == count, wire.periodEnd.count == count,
            wire.payoutRatio3y.count == count,
            wire.metrics.values.allSatisfy({ $0.count == count })
        else { return nil }
        return (0..<count).map { index in
            var metrics: [String: Double] = [:]
            for (key, column) in wire.metrics {
                if let value = column[index], value.isFinite { metrics[key] = value }
            }
            var years = Array(wire.payoutRatio3y[index].prefix(3))
            while years.count < 3 { years.insert(nil, at: 0) }
            return Row(
                code: wire.code[index], name: wire.name[index], market: wire.market[index],
                sector: wire.sector[index], periodEnd: wire.periodEnd[index],
                metrics: metrics, payoutRatio3y: years)
        }
    }

    private struct Wire: Decodable {
        var schemaVersion: Int
        var count: Int
        var code: [String]
        var name: [String]
        var market: [String]
        var sector: [String]
        var periodEnd: [String]
        var metrics: [String: [Double?]]
        var payoutRatio3y: [[Double?]]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case count, code, name, market, sector, metrics
            case periodEnd = "period_end"
            case payoutRatio3y = "payout_ratio_3y"
        }
    }
}
