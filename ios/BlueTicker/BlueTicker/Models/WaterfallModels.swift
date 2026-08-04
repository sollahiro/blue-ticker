import Foundation

/// GET /v1/companies/{code}/waterfall の公開契約（FinancialsContract.swift の analysisJsonObject()）のうち
/// Cube の3面（正面=事業利益ウォーターフォール／側面=5年推移／上面=計算ロジック）が使うフィールドのみを取り込む。
/// サーバーは全キーを返すが、未使用フィールドはデコード対象に含めない（クライアント側で不要な結合を避ける）。
struct WaterfallResponse: Codable {
    var code: String
    var name: String
    var sector: String
    var market: String
    var years: [WaterfallYear]
}

struct WaterfallYear: Codable, Identifiable {
    var fyEnd: String?
    var financialPeriod: String?
    var opLabel: String?

    var sales: Double?
    var grossProfit: Double?
    var sga: Double?
    var operatingProfit: Double?
    var netProfit: Double?

    var businessProfit: Double?
    var businessProfitMargin: Double?
    var businessProfitChange: Double?
    var salesChangeImpact: Double?
    var grossMarginChangeImpact: Double?
    var sgaChangeImpact: Double?

    var roe: Double?
    var roic: Double?

    var id: String { fyEnd ?? financialPeriod ?? "" }

    enum CodingKeys: String, CodingKey {
        case fyEnd = "fy_end"
        case financialPeriod = "financial_period"
        case opLabel = "op_label"
        case sales
        case grossProfit = "gross_profit"
        case sga
        case operatingProfit = "operating_profit"
        case netProfit = "net_profit"
        case businessProfit = "business_profit"
        case businessProfitMargin = "business_profit_margin"
        case businessProfitChange = "business_profit_change"
        case salesChangeImpact = "sales_change_impact"
        case grossMarginChangeImpact = "gross_margin_change_impact"
        case sgaChangeImpact = "sga_change_impact"
        case roe
        case roic
    }
}

/// Cube の3面が共通で選択対象にする「項目」。正面のバー選択・上面のカード選択のどちらからも
/// この値が決まり、側面（5年推移）はこの値の時系列を描く（`docs/ios-app-concept.md` の3面連動）。
enum WaterfallMetric: String, CaseIterable, Identifiable {
    case businessProfit
    case salesImpact
    case marginImpact
    case sgaImpact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .businessProfit: return "事業利益"
        case .salesImpact: return "売上要因"
        case .marginImpact: return "利益率変化"
        case .sgaImpact: return "販管費"
        }
    }
}

/// Cube 正面（事業利益増減ウォーターフォール）の1本のバー。
struct WaterfallBar: Identifiable {
    enum Kind: Equatable { case start, delta, end }

    var id: String { label }
    var label: String
    var value: Double
    var cumulativeStart: Double
    var kind: Kind
    var metric: WaterfallMetric
}

extension WaterfallYear {
    /// 前期事業利益 → 売上差影響 → 粗利率差影響 → 販管費差影響 → 当期事業利益 の5本バー。
    /// サーバーが返す `businessProfitChange` 系フィールドは前年比較込みで計算済み（クライアント側で再計算しない）。
    /// いずれか欠落時は nil（前年データが無い最古期など）。
    func businessProfitWaterfallBars() -> [WaterfallBar]? {
        // 金融機関(経常利益・事業利益ベース)は事業利益分解の対象外。
        // 既存CLI(AnalysisRendering.swift の bpAvailable)と同じ判定。
        guard !["経常利益", "事業利益"].contains(opLabel ?? ""),
            let current = businessProfit,
            let change = businessProfitChange,
            let salesImpact = salesChangeImpact,
            let marginImpact = grossMarginChangeImpact,
            let sgaImpact = sgaChangeImpact
        else { return nil }
        let prior = current - change

        var bars: [WaterfallBar] = []
        var cursor = prior
        bars.append(
            WaterfallBar(
                label: "前期事業利益", value: prior, cumulativeStart: 0, kind: .start,
                metric: .businessProfit))
        for (label, delta, metric) in [
            ("売上要因", salesImpact, WaterfallMetric.salesImpact),
            ("利益率変化", marginImpact, WaterfallMetric.marginImpact),
            ("販管費", sgaImpact, WaterfallMetric.sgaImpact),
        ] {
            // yEnd(描画側)は cumulativeStart + value で計算するため、符号によらず
            // 加算前の cursor を開始点にする(負のデルタは cursor から cursor+delta へ下向きに描かれる)。
            bars.append(
                WaterfallBar(label: label, value: delta, cumulativeStart: cursor, kind: .delta, metric: metric))
            cursor += delta
        }
        bars.append(
            WaterfallBar(
                label: "当期事業利益", value: current, cumulativeStart: 0, kind: .end,
                metric: .businessProfit))
        return bars
    }
}

extension WaterfallResponse {
    /// 側面（5年推移）用の時系列。API は新しい順で返すため、古い順に並べ替える。
    /// 値が nil の期はグラフ側で欠損として扱う。
    func series(for metric: WaterfallMetric) -> [(period: String, value: Double?)] {
        years.reversed().map { year in
            let label = year.financialPeriod ?? year.fyEnd ?? "-"
            switch metric {
            case .businessProfit: return (label, year.businessProfit)
            case .salesImpact: return (label, year.salesChangeImpact)
            case .marginImpact: return (label, year.grossMarginChangeImpact)
            case .sgaImpact: return (label, year.sgaChangeImpact)
            }
        }
    }
}
