// チャットへ渡すデータの整形。金額の単位換算・増減率はコードで計算し、
// モデルには「そのまま引用できる文字列」だけを渡す（モデルに桁計算をさせない）。

import Foundation

enum ChatFormat {
    // MARK: - 数値

    /// 円の金額を兆円・億円・万円の読みやすい表記にする。
    static func yen(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        if magnitude >= 1e12 {
            return sign + String(format: "%.2f兆円", magnitude / 1e12)
        }
        if magnitude >= 1e8 {
            let oku = magnitude / 1e8
            return sign + (oku >= 1000 ? grouped(oku.rounded()) : String(format: "%.1f", oku)) + "億円"
        }
        if magnitude >= 1e4 {
            return sign + grouped((magnitude / 1e4).rounded()) + "万円"
        }
        return sign + grouped(magnitude.rounded()) + "円"
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func signedPercent(_ value: Double) -> String {
        String(format: "%+.1f%%", value)
    }

    /// 前期比（%）。符号が変わる・前期がゼロなら率は出さない。
    static func growth(latest: Double, previous: Double) -> Double? {
        guard previous != 0, (latest >= 0) == (previous >= 0) else { return nil }
        return (latest - previous) / abs(previous) * 100
    }

    /// "2026-03-31" → "26年3月期"。
    static func periodLabel(_ fyEnd: String) -> String {
        let parts = fyEnd.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]) else {
            return fyEnd
        }
        return "\(year % 100)年\(month)月期"
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    // MARK: - 財務サマリー

    /// financials 応答（years は新しい順）から、直近 `maxYears` 期の主要指標を古い順に並べる。
    static func financialSummary(_ json: [String: Any], maxYears: Int = 3) -> String? {
        guard let years = json["years"] as? [[String: Any]], !years.isEmpty else { return nil }
        let ordered = Array(years.prefix(maxYears).reversed())
        var lines: [String] = []
        for (index, year) in ordered.enumerated() {
            let previous = index > 0 ? ordered[index - 1] : nil
            guard let line = yearLine(year, previous: previous) else { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static let amountItems: [(key: String, label: String, showsGrowth: Bool)] = [
        ("sales", "売上高", true),
        ("operating_profit", "営業利益", true),
        ("net_profit", "純利益", true),
        ("cfo", "営業CF", false),
        ("capex", "設備投資", false),
        ("rd", "研究開発費", false),
        ("total_assets", "総資産", false),
        ("net_assets", "純資産", false),
        ("interest_bearing_debt", "有利子負債", false),
        ("cash_equivalents", "現金同等物", false),
    ]

    private static let ratioItems: [(key: String, label: String)] = [
        ("gross_profit_margin", "粗利率"),
        ("operating_margin", "営業利益率"),
        ("roe", "ROE"),
        ("roic", "ROIC"),
    ]

    private static func yearLine(_ year: [String: Any], previous: [String: Any]?) -> String? {
        let label = (year["fy_end"] as? String).map(periodLabel) ?? "決算期不明"
        var parts: [String] = []
        for item in amountItems {
            guard let value = number(year[item.key]) else { continue }
            var text = "\(salesLabel(item, year)) \(yen(value))"
            if item.showsGrowth, let previous, let before = number(previous[item.key]) {
                if let rate = growth(latest: value, previous: before) {
                    text += "（前期比 \(signedPercent(rate))）"
                } else if before < 0, value >= 0 {
                    text += "（黒字化）"
                } else if before >= 0, value < 0 {
                    text += "（赤字化）"
                }
            }
            parts.append(text)
        }
        for item in ratioItems {
            guard let value = number(year[item.key]) else { continue }
            parts.append("\(item.label) \(percent(value))")
        }
        if let employees = number(year["employees"]) {
            parts.append("従業員数 \(grouped(employees))人")
        }
        if let eps = number(year["eps"]) {
            parts.append(String(format: "EPS %.2f円", eps))
        }
        guard !parts.isEmpty else { return nil }
        return "\(label): " + parts.joined(separator: "、")
    }

    /// 銀行など「売上高」以外の名称（経常収益など）を使う会社はラベルを差し替える。
    private static func salesLabel(
        _ item: (key: String, label: String, showsGrowth: Bool), _ year: [String: Any]
    ) -> String {
        if item.key == "sales", let label = year["sales_label"] as? String, !label.isEmpty {
            return label
        }
        if item.key == "operating_profit", let label = year["op_label"] as? String, !label.isEmpty {
            return label
        }
        return item.label
    }

    // MARK: - 内訳

    /// breakdown 応答の行を「名前: 売上 …（構成比 …）、利益 …（利益率 …）」に整形する。
    /// 内訳表の行で読む値（セル）と表示名。軸ごとにセル名が違う（金額・期末残高・設備投資額など）。
    private static let breakdownCells: [(key: String, label: String)] = [
        ("amount", "金額"),
        ("flow", "設備投資額"),
        ("capital_expenditures_overview", "設備投資（設備の状況）"),
        ("segment_assets", "セグメント資産"),
        ("opening", "期首"),
        ("closing", "期末"),
        ("amortization", "償却額"),
        ("impairment", "減損損失"),
    ]

    static func breakdownSummary(_ json: [String: Any]) -> String? {
        guard let breakdown = json["breakdown"] as? [String: Any],
            let rows = breakdown["rows"] as? [[String: Any]], !rows.isEmpty
        else { return nil }
        let unit = json["unit"] as? String ?? "currency_amount"
        func value(_ number: Double) -> String {
            switch unit {
            case "currency_amount": return yen(number)
            case "persons": return grouped(number) + "人"
            default: return grouped(number)
            }
        }
        /// セルの分母。金額は表の分母、ほかのセルは同名の分母（capex）か、期末なら表の分母。
        func denominator(for cell: String) -> Double? {
            if let nested = breakdown[cell] as? [String: Any] { return number(nested["denominator"]) }
            return cell == "amount" || cell == "closing" ? number(breakdown["denominator"]) : nil
        }
        let flowLabel = (breakdown["flow_metric"] as? String) == "noncurrent_asset_additions"
            ? "非流動資産の増加額" : "設備投資額"

        var lines: [String] = []
        for row in rows {
            let kind = row["row_kind"] as? String
            // 調整額・内部消去は利用者の問いにほぼ関係しないため除く。
            guard kind != "reconciling", let label = row["label"] as? String else { continue }
            let isTotal = kind == "subtotal" || kind == "EntityTotal"
            var parts: [String] = []
            for cell in breakdownCells {
                guard let amount = number(row[cell.key]) else { continue }
                let name: String
                switch cell.key {
                case "flow": name = flowLabel
                case "amount" where unit == "persons": name = "人数"
                case "amount" where unit != "currency_amount": name = "値"
                default: name = cell.label
                }
                var text = "\(name) \(value(amount))"
                if !isTotal, let total = denominator(for: cell.key), total > 0 {
                    text += "（構成比 \(percent(amount / total * 100))）"
                }
                parts.append(text)
            }
            if let profit = number(row["profit"]) {
                var text = "利益 \(yen(profit))"
                if let amount = number(row["amount"]), amount > 0 {
                    text += "（利益率 \(percent(profit / amount * 100))）"
                }
                parts.append(text)
            }
            guard !parts.isEmpty else { continue }
            var rowName = label
            switch row["maturity_class"] as? String {
            case "current": rowName += "（流動）"
            case "non_current": rowName += "（非流動）"
            default: break
            }
            // 有利子負債の明細行は貸借対照表の行と重複する（合計には含めない）。
            if row["in_total"] as? Bool == false { rowName += "〔明細〕" }
            lines.append((isTotal ? "［合計］" : "") + "\(rowName): " + parts.joined(separator: "、"))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - 本文の抜粋

    /// 段落単位で、先頭の段落とキーワードを含む段落を優先して `maxCharacters` 以内に収める。
    /// 元の並び順は保つ。切り詰めたときは末尾に印を付ける。
    /// これより長い段落は文に分ける。
    static let maxParagraphCharacters = 400

    /// 「。」で文に分ける（句点は文に残す）。
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "。" {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    static func excerpt(_ text: String, keywords: [String], maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }

        // 改行のない長い本文もあるため、長すぎる段落は文（。）で区切ってから選ぶ。
        let paragraphs = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { $0.count > maxParagraphCharacters ? sentences($0) : [$0] }
        let terms = keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let marker = "\n（以下略。必要なら別のキーワードで再取得できます）"
        let budget = max(0, maxCharacters - marker.count)

        // 優先度: キーワード一致数が多い段落 → 先頭に近い段落。
        let ranked = paragraphs.indices.sorted { lhs, rhs in
            let left = terms.filter { paragraphs[lhs].contains($0) }.count
            let right = terms.filter { paragraphs[rhs].contains($0) }.count
            return left != right ? left > right : lhs < rhs
        }
        var chosen = Set<Int>()
        var used = 0
        for index in ranked {
            let length = paragraphs[index].count + 1
            if used + length > budget {
                if chosen.isEmpty {
                    // 1段落目から予算を超える場合は段落の途中で切る。
                    return String(paragraphs[index].prefix(budget)) + marker
                }
                continue
            }
            chosen.insert(index)
            used += length
        }
        let body = chosen.sorted().map { paragraphs[$0] }.joined(separator: "\n")
        return body + marker
    }
}
