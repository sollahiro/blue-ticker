// 半期 financials API の公開契約。サーバーとクライアントで共有する単一の Codable 型。
//
// 設計意図（financials の FinancialsContract と同思想）:
// - サーバー（Stage 4-half ingest の computeHalfFinancials → JSONB 保存 → read で jsonObject()）は
//   この型で JSON を生成・保存し、remote CLI（RemoteAPIClient）は同じ型でデコードして [HalfPeriod] に
//   復元する（計算はサーバー集約・キー定義を 1 か所に集約しドリフトを防ぐ）。
// - 年度メトリクスは financials と同じ flatten 形（FinancialsYear）を再利用し、内部モデル
//   （YearEntry）を露出させない。半期固有のメタ（label / half）だけを period が足す。
// - trim は live・DB とも「5 年分を計算してから halfYearTrimPeriods で縮める」共通フローのため、
//   trimmed(toYears:) は halfYearTrimPeriods をそのまま再利用する（financials のような最古年
//   null 補正は不要。live も DB も同一の全集合から trim するため出力が一致する）。
//
// Foundation のみ依存（NIO/Vapor 非依存）。サーバー・CLI 双方から使う。

import Foundation

/// 半期 Stage 4 の計算結果。「対象外」（半期報告書が未提出等、設計通りで再提出待ち）と
/// 「失敗」（書類はあるが抽出できない、要調査）を区別する（issue #73 のフォローアップ）。
/// ingest サマリで前者を failed カウントへ混入させないために使う。
public enum HalfFinancialsComputeResult: Sendable {
    case success(HalfFinancialsResponse)
    case notApplicable
    case failed
}

/// Neon の半期 Stage 4 キャッシュ（`company_half_financials.cache_version`）の計算バージョン。
/// `blueTickerVersion` とは独立し、半期計算ロジック（HalfYearAnalyzer / buildH2Entry）または
/// 本契約型（HalfFinancialsResponse / HalfFinancialsPeriod）の意味を変えたときのみバンプする
/// （financials の `companyFinancialsCacheVersion` と同思想・全社再計算が高コストなため）。
public let companyHalfFinancialsCacheVersion = "half-v2"

/// half financials read（REST）が 200 を返す最低計算バージョン番号（`half-vN` の N）。
/// **明示指定**であり、「現行から N つ前」のような機械オフセットではない。人手で上げる。
/// ingest の stale 判定・書き込みは常に `companyHalfFinancialsCacheVersion`。床未満の行は 404。
/// 床の引き上げは、該当旧版の stale 消化が終わってから行う（引き上げ後に servable 穴を作らない）。
/// 不変条件: `companyHalfFinancialsMinServableVersion` ≤ 現行 `half-vN` の N。
public let companyHalfFinancialsMinServableVersion = 1

/// `half-vN` 形式から世代番号 N を取り出す。パース不能なら nil（非 servable 扱い）。
public func companyHalfFinancialsCacheVersionNumber(_ version: String) -> Int? {
    guard version.hasPrefix("half-v") else { return nil }
    let suffix = version.dropFirst("half-v".count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
    return n
}

/// 格納行の `cache_version` が read 床以上か。文字列辞書順比較は使わない（`half-v10` 対策）。
public func isServableCompanyHalfFinancialsCacheVersion(_ version: String) -> Bool {
    guard let n = companyHalfFinancialsCacheVersionNumber(version) else { return false }
    return n >= companyHalfFinancialsMinServableVersion
}

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

    /// Summarize（half-financials）応答用 JSON。`year` から Analyze 専用フィールドを除く。
    func summaryJsonObject() -> [String: Any] {
        ["label": label, "half": half as Any? ?? NSNull(), "year": year.summaryJsonObject()]
    }

    /// Analyze（half-analysis）応答用 JSON。`prior` は「同じ半期の直近過去期」（隣接期ではない）。
    func analysisJsonObject(prior: HalfFinancialsPeriod?) -> [String: Any] {
        ["label": label, "half": half as Any? ?? NSNull(), "year": year.analysisJsonObject(prior: prior?.year)]
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

    /// Summarize（half-financials）応答用の全キー JSON オブジェクト（`periods` 各要素の `year` は
    /// Analyze 専用フィールドを除いた水準値のみ）。public: BltServerCore の half-financials read 経路が使う。
    public func summaryJsonObject() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "code": code,
            "name": name,
            "currency": currency,
            "unit": unit,
            "periods": periods.map { $0.summaryJsonObject() },
        ]
    }

    /// Analyze（half-analysis）応答用の全キー JSON オブジェクト。`periods`（古い順）を走査し、
    /// 各期に「同じ半期の直近過去期」との増減分解フィールド（④⑤ブロック含む）を付与する。
    /// 呼び出し側は `trimmed(toYears:)` を先に適用してから呼ぶこと。
    /// public: BltServerCore の half-analysis read 経路が使う。
    public func analysisJsonObject() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "code": code,
            "name": name,
            "currency": currency,
            "unit": unit,
            "periods": periods.indices.map { i in
                let prior = periods[..<i].last { $0.half == periods[i].half }
                return periods[i].analysisJsonObject(prior: prior)
            },
        ]
    }

    /// 直近 n 年度ぶんに縮めたコピーを返す。live・DB とも全集合から同一ロジックで trim する
    /// （halfYearTrimPeriods は完結 H1+H2 ペア n 件 ＋ 当期 H1 を残す）。
    public func trimmed(toYears n: Int) -> HalfFinancialsResponse {
        var copy = self
        copy.periods = halfYearTrimPeriods(toPeriods(), to: n).map { HalfFinancialsPeriod($0) }
        return copy
    }

    /// 半期報告書未提出等、計算対象外だった企業のプレースホルダ（`periods` 空）。
    /// public: Stage 4-half ingest（BltServerCore）が `.notApplicable` 判定時にこの行を保存し、
    /// 次回 ingest で highWater 一致のまま無駄な再計算を繰り返さないようにするために使う
    /// （読み取り経路 `loadStoredHalfFinancials`/`loadStoredHalfAnalysis` は `periods` 空を検出し
    /// 404 を維持する。annual 側の `FinancialsResponse.notApplicablePlaceholder` と同型）。
    public static func notApplicablePlaceholder(code: String) -> HalfFinancialsResponse {
        HalfFinancialsResponse(
            schemaVersion: Api.halfFinancialsSchemaVersion, code: code, name: "",
            currency: "JPY", unit: "百万円", periods: [])
    }

    /// 格納済み `periods` の件数。public: Stage 4-half read 経路（BltServerCore）が
    /// notApplicable プレースホルダ（`periods` 空）を検出して 404 を維持するために使う。
    public var periodCount: Int { periods.count }
}
