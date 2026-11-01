import Foundation

/// チャットに渡す 1 決算期の値。金額は通貨の基本単位（円なら円）、率は %（12.3 なら 12.3%）。
/// iOS の `FinancialsYear` から必要なキーだけ写す。
struct ChatFactYear: Sendable, Equatable {
    /// 決算期末（`2026-03-31`）。
    var fyEnd: String
    var sales: Double?
    var operatingProfit: Double?
    var operatingMargin: Double?
    var netProfit: Double?
    var roe: Double?
    var roic: Double?
    var employees: Int?
    /// 要因の説明用。売上総利益率（%）と販管費（金額）。
    var grossProfitMargin: Double?
    var sga: Double?
    /// 事業利益（売上総利益 − 販管費）の前期差と、その売上・利益率・販管費の要因（金額）。
    var businessProfitChange: Double?
    var salesChangeImpact: Double?
    var grossMarginChangeImpact: Double?
    var sgaChangeImpact: Double?
    /// ROE のデュポン分解（純利益率は %、回転率とレバレッジは倍）。
    var netMargin: Double?
    var assetTurnover: Double?
    var financialLeverage: Double?

    init(
        fyEnd: String,
        sales: Double? = nil,
        operatingProfit: Double? = nil,
        operatingMargin: Double? = nil,
        netProfit: Double? = nil,
        roe: Double? = nil,
        roic: Double? = nil,
        employees: Int? = nil,
        grossProfitMargin: Double? = nil,
        sga: Double? = nil,
        businessProfitChange: Double? = nil,
        salesChangeImpact: Double? = nil,
        grossMarginChangeImpact: Double? = nil,
        sgaChangeImpact: Double? = nil,
        netMargin: Double? = nil,
        assetTurnover: Double? = nil,
        financialLeverage: Double? = nil
    ) {
        self.fyEnd = fyEnd
        self.sales = sales
        self.operatingProfit = operatingProfit
        self.operatingMargin = operatingMargin
        self.netProfit = netProfit
        self.roe = roe
        self.roic = roic
        self.employees = employees
        self.grossProfitMargin = grossProfitMargin
        self.sga = sga
        self.businessProfitChange = businessProfitChange
        self.salesChangeImpact = salesChangeImpact
        self.grossMarginChangeImpact = grossMarginChangeImpact
        self.sgaChangeImpact = sgaChangeImpact
        self.netMargin = netMargin
        self.assetTurnover = assetTurnover
        self.financialLeverage = financialLeverage
    }

    /// 販管費率（%）。売上高に対する販管費。
    var sgaRatio: Double? {
        guard let sga, let sales, sales != 0 else { return nil }
        return sga / sales * 100
    }

    /// 従業員 1 人あたり売上高（金額）。
    var salesPerEmployee: Double? {
        guard let sales, let employees, employees > 0 else { return nil }
        return sales / Double(employees)
    }

    /// 期末の西暦年。`2026-03-31` なら 2026。
    var fiscalYear: Int? { Int(fyEnd.prefix(4)) }
}

/// チャットで扱う指標。並びは根拠テーブルの行順。
enum ChatFactMetric: String, CaseIterable, Sendable {
    case sales
    case operatingProfit
    case operatingMargin
    case netProfit
    case roe
    case roic
    case employees

    enum Kind: Sendable {
        /// 金額。前期比は %、符号が変わったら黒字化・赤字化。
        case amount
        /// 率（%）。前期差は pt。
        case percent
        /// 人数。前期比は %。
        case count
    }

    var label: String {
        switch self {
        case .sales: "売上高"
        case .operatingProfit: "営業利益"
        case .operatingMargin: "営業利益率"
        case .netProfit: "純利益"
        case .roe: "ROE"
        case .roic: "ROIC"
        case .employees: "従業員数"
        }
    }

    var kind: Kind {
        switch self {
        case .sales, .operatingProfit, .netProfit: .amount
        case .operatingMargin, .roe, .roic: .percent
        case .employees: .count
        }
    }

    func value(in year: ChatFactYear) -> Double? {
        switch self {
        case .sales: year.sales
        case .operatingProfit: year.operatingProfit
        case .operatingMargin: year.operatingMargin
        case .netProfit: year.netProfit
        case .roe: year.roe
        case .roic: year.roic
        case .employees: year.employees.map(Double.init)
        }
    }
}

/// 前期からの向き。生成モデルに「上昇／低下」を推測させず、コードで決めて渡す。
enum ChatFactDirection: Sendable, Equatable {
    case up
    case down
    case flat
    /// 赤字から黒字へ。
    case turnedPositive
    /// 黒字から赤字へ。
    case turnedNegative

    var word: String {
        switch self {
        case .up: "増加"
        case .down: "減少"
        case .flat: "横ばい"
        case .turnedPositive: "黒字化"
        case .turnedNegative: "赤字化"
        }
    }
}

/// 根拠テーブルの 1 行。表示文字列はコードで作り、文章側もこの文字列だけを使う。
struct ChatFactRow: Sendable, Equatable, Identifiable {
    var metric: ChatFactMetric
    /// 前期の値。前期が無ければ "—"。
    var previous: String
    var latest: String
    /// 前期比（`+15.0%`）または前期差（`+1.2pt`）。出せなければ nil。
    var change: String?
    var direction: ChatFactDirection?
    /// 直近 3 期が同じ向きに動いたときの一言（`3期連続で増加`）。
    var streak: String?

    var id: String { metric.rawValue }
    var label: String { metric.label }
}

/// 結果画面のチャットに渡す数字一式。前期比・前期差・連続増減はここで計算し、
/// 生成モデルには文章化だけをさせる。
struct ChatFacts: Sendable {
    /// 古い順。`fyEnd` が空の年度は落とす。
    let years: [ChatFactYear]
    /// 最新期の表記（`26年3月期`）。
    let latestPeriod: String
    let previousPeriod: String?
    let rows: [ChatFactRow]
    /// 最新期の「なぜ」に答える材料（要因分解・原価率・販管費率・デュポン分解）。1 行 1 項目。
    let driverLines: [String]
    private let amountText: @Sendable (Double) -> String

    /// `amountText` は金額（通貨の基本単位）を画面と同じ表記にする（例: `1,419億円`）。
    /// 最新期に値のある指標が 1 つも無ければ nil。
    init?(years raw: [ChatFactYear], amountText: @escaping @Sendable (Double) -> String) {
        let years = raw
            .filter { !$0.fyEnd.isEmpty }
            .sorted { $0.fyEnd < $1.fyEnd }
        guard let latest = years.last else { return nil }
        let previous = years.count >= 2 ? years[years.count - 2] : nil
        self.years = years
        self.amountText = amountText
        latestPeriod = Self.periodLabel(latest.fyEnd)
        previousPeriod = previous.map { Self.periodLabel($0.fyEnd) }

        var rows: [ChatFactRow] = []
        for metric in ChatFactMetric.allCases {
            guard let latestValue = metric.value(in: latest) else { continue }
            let previousValue = previous.flatMap { metric.value(in: $0) }
            let change = Self.change(metric: metric, previous: previousValue, latest: latestValue)
            rows.append(
                ChatFactRow(
                    metric: metric,
                    previous: previousValue.map { Self.text(metric: metric, value: $0, amountText: amountText) } ?? "—",
                    latest: Self.text(metric: metric, value: latestValue, amountText: amountText),
                    change: change?.text,
                    direction: change?.direction,
                    streak: Self.streak(metric: metric, years: years)
                )
            )
        }
        guard !rows.isEmpty else { return nil }
        self.rows = rows
        driverLines = Self.drivers(latest: latest, previous: previous, amountText: amountText)
    }

    /// 生成モデルの指示に載せる数字の行。1 指標 1 行。
    var promptLines: String {
        rows.map { row in
            var line = "\(row.label): "
            if let previousPeriod, row.previous != "—" {
                line += "\(previousPeriod) \(row.previous) → "
            }
            line += "\(latestPeriod) \(row.latest)"
            var notes: [String] = []
            if let change = row.change, let direction = row.direction {
                let prefix = row.metric.kind == .percent ? "前期差" : "前期比"
                notes.append("\(prefix) \(change)、\(direction.word)")
            } else if let direction = row.direction {
                notes.append(direction.word)
            }
            if let streak = row.streak {
                notes.append(streak)
            }
            if !notes.isEmpty {
                line += "（\(notes.joined(separator: "。"))）"
            }
            return line
        }
        .joined(separator: "\n")
    }

    /// 取得できる決算期の表記（古い順）。
    var periodLabels: [String] {
        years.map { Self.periodLabel($0.fyEnd) }
    }

    /// ツールの応答。指定した決算期（期末の西暦年）の値を 1 行で返す。
    /// 同じ年に期末が 2 つある（決算期変更）ときは後の期。
    func yearDetail(fiscalYear raw: Int) -> String {
        let fiscalYear = Self.normalizedFiscalYear(raw)
        guard let year = years.last(where: { $0.fiscalYear == fiscalYear }) else {
            let available = periodLabels.joined(separator: "、")
            return "その決算期のデータはありません。取得できる決算期: \(available)"
        }
        let parts = ChatFactMetric.allCases.compactMap { metric -> String? in
            guard let value = metric.value(in: year) else { return nil }
            return "\(metric.label) \(Self.text(metric: metric, value: value, amountText: amountText))"
        }
        let period = Self.periodLabel(year.fyEnd)
        guard !parts.isEmpty else { return "\(period): 値がありません。" }
        var detail = "\(period): " + parts.joined(separator: "、")
        let index = years.lastIndex(of: year)
        let prior = index.flatMap { $0 > 0 ? years[$0 - 1] : nil }
        let drivers = Self.drivers(latest: year, previous: prior, amountText: amountText)
        if !drivers.isEmpty {
            detail += "\n" + drivers.joined(separator: "\n")
        }
        return detail
    }

    /// モデルが「26年3月期」の 26 だけを渡すことがあるので、2 桁は 2000 年代とみなす。
    static func normalizedFiscalYear(_ year: Int) -> Int {
        (0..<100).contains(year) ? 2000 + year : year
    }

    /// 円の金額を、桁を読み違えにくい億円・百万円で書く（`15,840億円`）。十億円は使わない。
    static func yenText(_ yen: Double) -> String {
        let absolute = abs(yen)
        let sign = yen < 0 ? "-" : ""
        if absolute >= 100_000_000 {
            return sign + grouped(Int((absolute / 100_000_000).rounded())) + "億円"
        }
        return sign + grouped(Int((absolute / 1_000_000).rounded())) + "百万円"
    }

    // MARK: - 要因

    /// 「なぜ」に答える材料。値はすべてコードで計算し、モデルには言い換えだけをさせる。
    static func drivers(
        latest: ChatFactYear,
        previous: ChatFactYear?,
        amountText: (Double) -> String
    ) -> [String] {
        var lines: [String] = []
        let period = periodLabel(latest.fyEnd)
        func signedAmount(_ value: Double) -> String {
            value > 0 ? "+" + amountText(value) : amountText(value)
        }
        if let change = latest.businessProfitChange {
            var factors: [String] = []
            if let value = latest.salesChangeImpact { factors.append("売上の増減による分 \(signedAmount(value))") }
            if let value = latest.grossMarginChangeImpact { factors.append("粗利率（売上総利益率）の変化による分 \(signedAmount(value))") }
            if let value = latest.sgaChangeImpact { factors.append("販管費の増減による分 \(signedAmount(value))") }
            var line = "\(period)の事業利益（売上総利益−販管費）の前期差: \(signedAmount(change))"
            if !factors.isEmpty {
                line += "。内訳は " + factors.joined(separator: "、") + "（プラスは利益を押し上げ、マイナスは押し下げ）"
            }
            lines.append(line)
        }
        lines += ratioLine("粗利率（売上総利益率）", latest.grossProfitMargin, previous?.grossProfitMargin, period: period, previousPeriod: previous.map { periodLabel($0.fyEnd) }, unit: .percent)
        lines += ratioLine("販管費率（売上高に対する販管費）", latest.sgaRatio, previous?.sgaRatio, period: period, previousPeriod: previous.map { periodLabel($0.fyEnd) }, unit: .percent)
        let dupont = [
            ("純利益率", latest.netMargin, previous?.netMargin, RatioUnit.percent),
            ("総資産回転率", latest.assetTurnover, previous?.assetTurnover, RatioUnit.times),
            ("財務レバレッジ", latest.financialLeverage, previous?.financialLeverage, RatioUnit.times),
        ].compactMap { label, now, before, unit -> String? in
            guard let now else { return nil }
            if let before {
                return "\(label) \(unit.text(before)) → \(unit.text(now))"
            }
            return "\(label) \(unit.text(now))"
        }
        if !dupont.isEmpty {
            lines.append("ROEの分解（ROE = 純利益率 × 総資産回転率 × 財務レバレッジ）: " + dupont.joined(separator: "、"))
        }
        if let now = latest.salesPerEmployee {
            var line = "従業員1人あたり売上高: "
            if let before = previous?.salesPerEmployee {
                line += "\(amountText(before)) → "
            }
            line += amountText(now)
            lines.append(line)
        }
        return lines
    }

    enum RatioUnit {
        case percent
        case times

        func text(_ value: Double) -> String {
            switch self {
            case .percent: String(format: "%.1f%%", value)
            case .times: String(format: "%.2f倍", value)
            }
        }
    }

    private static func ratioLine(
        _ label: String,
        _ latest: Double?,
        _ previous: Double?,
        period: String,
        previousPeriod: String?,
        unit: RatioUnit
    ) -> [String] {
        guard let latest else { return [] }
        guard let previous, let previousPeriod else {
            return ["\(label): \(period) \(unit.text(latest))"]
        }
        let diff = latest - previous
        let word = abs(diff) < 0.05 ? "横ばい" : (diff > 0 ? "上昇" : "低下")
        return ["\(label): \(previousPeriod) \(unit.text(previous)) → \(period) \(unit.text(latest))（前期差 \(signed(diff, unit: "pt"))、\(word)）"]
    }

    // MARK: - 計算

    /// `2026-03-31` → `26年3月期`。
    static func periodLabel(_ fyEnd: String) -> String {
        guard fyEnd.count >= 7,
              let year = Int(fyEnd.prefix(4)),
              let month = Int(fyEnd.dropFirst(5).prefix(2))
        else { return fyEnd }
        return "\(year % 100)年\(month)月期"
    }

    static func text(metric: ChatFactMetric, value: Double, amountText: (Double) -> String) -> String {
        switch metric.kind {
        case .amount:
            amountText(value)
        case .percent:
            String(format: "%.1f%%", value)
        case .count:
            grouped(Int(value.rounded())) + "人"
        }
    }

    static func change(
        metric: ChatFactMetric,
        previous: Double?,
        latest: Double
    ) -> (text: String?, direction: ChatFactDirection)? {
        guard let previous else { return nil }
        switch metric.kind {
        case .percent:
            let diff = latest - previous
            return (signed(diff, unit: "pt"), direction(diff, threshold: 0.05))
        case .amount, .count:
            if metric.kind == .amount {
                if previous < 0, latest > 0 { return (nil, .turnedPositive) }
                if previous > 0, latest < 0 { return (nil, .turnedNegative) }
            }
            guard previous != 0 else { return nil }
            let ratio = (latest - previous) / abs(previous) * 100
            return (signed(ratio, unit: "%"), direction(ratio, threshold: 0.05))
        }
    }

    /// 直近 3 期の値が欠けずに同じ向きへ動いたら「3期連続で増加」。それ以上さかのぼれる分も数える。
    static func streak(metric: ChatFactMetric, years: [ChatFactYear]) -> String? {
        let values = years.map { metric.value(in: $0) }
        var count = 0
        var sign = 0
        var index = values.count - 1
        while index >= 1, let current = values[index], let previous = values[index - 1] {
            let step = current > previous ? 1 : (current < previous ? -1 : 0)
            if step == 0 { break }
            if sign == 0 { sign = step } else if step != sign { break }
            count += 1
            index -= 1
        }
        // 前期比が 2 回続いて初めて「連続」と言う（3 期分の値）。
        guard count >= 2 else { return nil }
        let word: String
        switch metric.kind {
        case .percent: word = sign > 0 ? "上昇" : "低下"
        case .amount, .count: word = sign > 0 ? "増加" : "減少"
        }
        return "\(count)期連続で\(word)"
    }

    private static func direction(_ value: Double, threshold: Double) -> ChatFactDirection {
        if value > threshold { return .up }
        if value < -threshold { return .down }
        return .flat
    }

    static func signed(_ value: Double, unit: String) -> String {
        let rounded = (value * 10).rounded() / 10
        let body = String(format: "%.1f", abs(rounded))
        if rounded > 0 { return "+" + body + unit }
        if rounded < 0 { return "−" + body + unit }
        return "±0.0" + unit
    }

    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, char) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(char)
        }
        return (value < 0 ? "-" : "") + out
    }
}

/// 生成モデルに渡す文字列の切り詰め。端末内モデルは文脈が約 4,000 トークンしかない。
enum ChatContext {
    /// 全角の数字・記号を半角へ。端末内モデルは数字を全角で書くことがある。
    static func normalizedDigits(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF10...0xFF19:
                out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            case 0xFF0B: out.append("+")
            case 0xFF0D: out.append("-")
            case 0xFF0E: out.append(".")
            case 0xFF05: out.append("%")
            case 0xFF0C: out.append(",")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// `maxCharacters` 以内に収める。収まらないときは上限より前の最後の「。」で切る（無ければ字数で切って…）。
    static func clipped(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let head = String(trimmed.prefix(maxCharacters))
        if let end = head.lastIndex(of: "。"), head.distance(from: head.startIndex, to: end) >= maxCharacters / 2 {
            return String(head[...end])
        }
        return String(head.prefix(max(maxCharacters - 1, 0))) + "…"
    }

    struct Exchange: Sendable, Equatable {
        var question: String
        var answer: String
    }

    /// 文脈があふれて会話を作り直すとき、新しい指示へ持ち越す直近のやりとり。
    /// 新しいものから詰め、合計 `maxCharacters` を超える古いものは落とす。1 件も入らなければ nil。
    static func carriedExchanges(_ exchanges: [Exchange], maxCharacters: Int = 600) -> String? {
        var lines: [String] = []
        var used = 0
        for exchange in exchanges.reversed() {
            let answerBudget = max(maxCharacters / 2, 0)
            let line = "利用者: \(clipped(exchange.question, maxCharacters: 120))\n回答: \(clipped(exchange.answer, maxCharacters: answerBudget))"
            if used + line.count > maxCharacters { break }
            lines.insert(line, at: 0)
            used += line.count
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
