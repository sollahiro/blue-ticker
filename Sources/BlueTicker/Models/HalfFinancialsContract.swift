// 半期 financials API の公開契約。サーバーとクライアントで共有する単一の Codable 型。
//
// 設計意図（financials の FinancialsContract と同思想）:
// - サーバー（BltServerContext.getHalfFinancials / Stage 4-half ingest）はこの型で JSON を
//   生成・JSONB 保存し、remote CLI（RemoteAPIClient）は同じ型でデコードして [HalfPeriod] に
//   復元する（計算はサーバー集約・キー定義を 1 か所に集約しドリフトを防ぐ）。
// - 年度メトリクスは financials と同じ flatten 形（FinancialsYear）を再利用し、内部モデル
//   （YearEntry）を露出させない。半期固有のメタ（label / half）だけを period が足す。
// - trim は live・DB とも「5 年分を計算してから halfYearTrimPeriods で縮める」共通フローのため、
//   trimmed(toYears:) は halfYearTrimPeriods をそのまま再利用する（financials のような最古年
//   null 補正は不要。live も DB も同一の全集合から trim するため出力が一致する）。
//
// Foundation のみ依存（NIO/Vapor 非依存）。サーバー・CLI 双方から使う。

import Foundation

/// Neon の半期 Stage 4 キャッシュ（`company_half_financials.cache_version`）の計算バージョン。
/// `blueTickerVersion` とは独立し、半期計算ロジック（HalfYearAnalyzer / buildH2Entry）または
/// 本契約型（HalfFinancialsResponse / HalfFinancialsPeriod）の意味を変えたときのみバンプする
/// （financials の `companyFinancialsCacheVersion` と同思想・全社再計算が高コストなため）。
public let companyHalfFinancialsCacheVersion = "half-v1"

// MARK: - 半期エントリ（label/half ＋ flatten 形）

struct HalfFinancialsPeriod: Codable, Sendable {
    var label: String        // "24H1" / "24H2"
    var half: String?        // "H1" / "H2"
    var year: FinancialsYear  // financials と同じ flatten 形を再利用

    enum CodingKeys: String, CodingKey {
        case label, half, year
    }

    /// 内部モデル（HalfPeriod）→ 公開形。fyEnd は year.fyEnd（HalfPeriod.fyEnd と一致）に含まれる。
    init(_ p: HalfPeriod) {
        label = p.label
        half = p.half
        year = FinancialsYear(p.yearEntry)
    }

    /// 公開形 → 内部モデル（HalfPeriod）。remote CLI が既存レンダラへ渡すために復元する。
    func toHalfPeriod() -> HalfPeriod {
        HalfPeriod(label: label, half: half, fyEnd: year.fyEnd, yearEntry: year.toYearEntry())
    }

    /// 全キーを含む JSON オブジェクト（year は null 補完済み）。サーバー応答用。
    func jsonObject() -> [String: Any] {
        ["label": label, "half": half as Any? ?? NSNull(), "year": year.jsonObject()]
    }
}

// MARK: - レスポンス（トップレベル封筒）

// public: BltServerCore（半期 Stage 4 derived キャッシュ）がこの型を JSONB として保存・読込する。
public struct HalfFinancialsResponse: Codable, Sendable {
    var schemaVersion: Int
    var code: String
    var name: String
    var currency: String
    var unit: String
    var periods: [HalfFinancialsPeriod]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, name, currency, unit, periods
    }
}

extension HalfFinancialsResponse {
    /// 内部モデル（[HalfPeriod]）→ 公開契約レスポンス。サーバー側で使う。
    init(code: String, name: String, periods: [HalfPeriod]) {
        schemaVersion = Api.halfFinancialsSchemaVersion
        self.code = code
        self.name = name
        currency = "JPY"
        unit = "百万円"
        self.periods = periods.map { HalfFinancialsPeriod($0) }
    }

    /// 公開契約レスポンス → 内部モデル（[HalfPeriod]）。remote CLI が既存レンダラへ渡す。
    func toPeriods() -> [HalfPeriod] {
        periods.map { $0.toHalfPeriod() }
    }

    /// 全キーを含む JSON オブジェクト（periods 各要素も null 補完する）。サーバー応答用。
    /// public: BltServerCore の半期 read 経路が格納済みレスポンスを JSON へ落とすために使う。
    public func jsonObject() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "code": code,
            "name": name,
            "currency": currency,
            "unit": unit,
            "periods": periods.map { $0.jsonObject() },
        ]
    }

    /// 直近 n 年度ぶんに縮めたコピーを返す。live・DB とも全集合から同一ロジックで trim する
    /// （halfYearTrimPeriods は完結 H1+H2 ペア n 件 ＋ 当期 H1 を残す）。
    public func trimmed(toYears n: Int) -> HalfFinancialsResponse {
        var copy = self
        copy.periods = halfYearTrimPeriods(toPeriods(), to: n).map { HalfFinancialsPeriod($0) }
        return copy
    }
}
