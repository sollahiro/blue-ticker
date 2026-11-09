// geography 行のセル `assets`: 地域ごとの情報の有形固定資産（日本基準）／非流動資産（IFRS）。
//
// 地域売上の経路（LLM の列選択）は資産の表を落とすので、ここで別に読む。決定論だけで、
// 当期・単位・表の向きが確定できる表に限る。確定できないとき、地域の和が合計と合わないときは
// セルを付けない（fail closed）。行は geography 行の地域名と突き合わせ、合わない地域は捨てて警告にする。
//
// 読む表:
// - 直近の指標キャプションが「有形固定資産」「非流動資産」の表（日本基準の「(2) 有形固定資産」、IFRS の「② 非流動資産」）。
//   横（見出し行が地域・数値行が1行）と縦（行が地域・数値列が1列、または前期/当期の2列から当期）を受ける。
// - 売上と資産を1表に並べた横の表の「有形固定資産」「非流動資産」行（S100YG81 型）。
// 期間は表のキャプション・見出し、無ければ TextBlock の contextRef。当期の表が1つに決まらなければ付けない。

import Foundation
import SwiftSoup

enum GeographyAssetCells {
    /// 資産の表にあって geography 行に無い地域（捨てた）。
    static let warningUnmatchedRows = "geography_asset_rows_unmatched"

    /// `assets_metric` の値。
    static let metricPropertyPlantEquipment = geographyAssetsMetricPropertyPlantEquipment
    static let metricNoncurrentAssets = geographyAssetsMetricNoncurrentAssets

    /// 分母タグ: 表の合計の列・行。
    static let denominatorTagTableTotal = "table_total"
    /// 分母タグ: 合計が無い表の地域の和。
    static let denominatorTagRowSum = "row_sum"

    struct Entry: Equatable {
        var label: String
        var value: Double
    }

    struct Parsed: Equatable {
        var entries: [Entry]
        /// 表の合計（円）。合計の無い表は nil。
        var total: Double?
        /// 前期/当期の列から当期を選んだ。
        var pickedCurrentColumn: Bool
    }

    struct Table: Equatable {
        var metric: String
        var parsed: Parsed
        var period: String?
    }

    private static let totalLabels: Set<String> = ["合計", "計", "連結", "総計", "合計額", "連結合計", "連結計"]
    private static let currentHeaderKeywords = ["当連結会計年度", "当事業年度", "当年度", "当期"]
    private static let priorHeaderKeywords = ["前連結会計年度", "前事業年度", "前年度", "前期"]
    /// 指標キャプション・行ラベルのうち、残高でない行（増加額・減損・減価償却）。
    private static let nonBalanceWords = ["増加", "減損", "減価償却", "取得", "売却", "除却"]

    /// 読む TextBlock。US-GAAP の注記全体（地域以外の表を多く含む）とセグメント注記は読まない。
    static let textBlockTags: Set<String> = [
        "InformationAboutGeographicalAreasIFRSTextBlock",
        "InformationAboutGeographicalAreasTextBlock",
        "InformationAboutGeographicalAreasUSGAAPTextBlock",
        "RelatedInformationTextBlock",
    ]

    // MARK: - 書類

    /// 書類の当期の地域資産表。1つに決まらなければ nil。
    static func extract(xbrlDir: URL) -> Table? {
        let fiscalYearEnd = BreakdownExtractor.currentFiscalYearEnd(fromXbrlDir: xbrlDir)
        var tables: [Table] = []
        for block in BreakdownExtractor.textBlocks(xbrlDir: xbrlDir, tags: textBlockTags) {
            guard block.content.lowercased().contains("<table") else { continue }
            let contextPeriod = BreakdownExtractor.periodLabel(fromContextRef: block.contextRef)
            tables += candidates(html: block.content, contextPeriod: contextPeriod, fiscalYearEnd: fiscalYearEnd)
        }
        return select(tables)
    }

    /// 当期の表を1つ選ぶ。期間の分からない表は、それしか無いときだけ当期とみなす。
    static func select(_ tables: [Table]) -> Table? {
        let current = tables.filter { $0.period == "当期" || $0.parsed.pickedCurrentColumn }
        let pool = current.isEmpty ? tables.filter { $0.period == nil } : current
        guard let first = pool.first else { return nil }
        if current.isEmpty, pool.count != 1 { return nil }
        // 同じ表が二重に読まれる（訂正・改ページ）のは許す。中身が違えば決められない。
        guard pool.allSatisfy({ $0.parsed == first.parsed && $0.metric == first.metric }) else { return nil }
        return first
    }

    static func candidates(html: String, contextPeriod: String?, fiscalYearEnd: String?) -> [Table] {
        guard let soup = try? SwiftSoup.parse(html), let elements = try? soup.select("table") else { return [] }
        var out: [Table] = []
        for element in elements {
            let grid = BreakdownExtractor.expandTable(element)
            guard grid.count >= 2 else { continue }
            let (caption, _) = BreakdownExtractor.resolvedUnitCaption(grid: grid, pending: nil, table: element)
            guard let unit = caption.flatMap(AmountUnit.yenMultiplier(containedIn:)) ?? unitInHeader(grid) else {
                continue
            }
            let period = BreakdownExtractor.detectPeriod(table: element, grid: grid, fiscalYearEnd: fiscalYearEnd)?.0
                ?? contextPeriod
            if let metricCaption = BreakdownExtractor.nearestGeographyMetricCaption(before: element),
                BreakdownExtractor.isGeographyAssetMetricCaption(metricCaption),
                let metric = assetMetric(metricCaption)
            {
                if let parsed = parseWhole(grid: grid, unit: unit) {
                    out.append(Table(metric: metric, parsed: parsed, period: period))
                }
                continue
            }
            if let (metric, parsed) = parseAssetRow(grid: grid, unit: unit) {
                out.append(Table(metric: metric, parsed: parsed, period: period))
            }
        }
        return out
    }

    // MARK: - 表（純関数）

    /// 指標の語。残高でない語（増加額・減損）を含むと nil。
    static func assetMetric(_ text: String) -> String? {
        let t = compact(text)
        if nonBalanceWords.contains(where: t.contains) { return nil }
        if t.contains("有形固定資産") { return metricPropertyPlantEquipment }
        if t.contains("非流動資産") { return metricNoncurrentAssets }
        return nil
    }

    /// 資産だけの表。横（見出し行が地域）を先に、だめなら縦（行が地域）を試す。
    static func parseWhole(grid: [[String]], unit: Double) -> Parsed? {
        let rows = cleaned(grid)
        guard rows.count >= 2 else { return nil }
        if let header = rows.firstIndex(where: isLabelRow) {
            let dataRows = rows[(header + 1)...].filter { row in row.dropFirst().contains { amount($0) != nil } }
            if dataRows.count == 1, let parsed = horizontal(header: rows[header], values: dataRows[0], unit: unit) {
                return parsed
            }
            // 前期・当期の2行（行ラベルが期間）は当期の行だけ。
            let currentRows = dataRows.filter { row in
                let label = compact(row.first ?? "")
                return currentHeaderKeywords.contains(where: label.contains)
                    && !priorHeaderKeywords.contains(where: label.contains)
            }
            if dataRows.count > 1, currentRows.count == 1,
                var parsed = horizontal(header: rows[header], values: currentRows[0], unit: unit)
            {
                parsed.pickedCurrentColumn = true
                return parsed
            }
        }
        return vertical(rows: rows, unit: unit)
    }

    /// 売上と資産を並べた横の表の資産行。
    static func parseAssetRow(grid: [[String]], unit: Double) -> (String, Parsed)? {
        let rows = cleaned(grid)
        guard let header = rows.firstIndex(where: isLabelRow) else { return nil }
        let assetRows = rows[(header + 1)...].compactMap { row -> (String, [String])? in
            guard let label = row.first, let metric = assetRowMetric(label) else { return nil }
            return (metric, row)
        }
        guard assetRows.count == 1, let row = assetRows.first,
            let parsed = horizontal(header: rows[header], values: row.1, unit: unit)
        else { return nil }
        return (row.0, parsed)
    }

    /// 行ラベルが「有形固定資産」「非流動資産」だけ（注記番号を除く）。
    private static func assetRowMetric(_ label: String) -> String? {
        let t = stripNoteMarks(compact(label))
        if t == "有形固定資産" { return metricPropertyPlantEquipment }
        if t == "非流動資産" { return metricNoncurrentAssets }
        return nil
    }

    private static func horizontal(header: [String], values: [String], unit: Double) -> Parsed? {
        var labels: [String] = []
        var amounts: [Double] = []
        for column in 1..<max(header.count, 1) {
            let label = column < header.count ? header[column] : ""
            let cell = column < values.count ? values[column] : ""
            if compact(label).isEmpty, compact(cell).isEmpty { continue }
            guard !compact(label).isEmpty, let value = amount(cell) else { return nil }
            labels.append(label)
            amounts.append(value * unit)
        }
        return build(labels: labels, amounts: amounts, unit: unit, pickedCurrentColumn: false)
    }

    private static func vertical(rows: [[String]], unit: Double) -> Parsed? {
        // 見出し行（地域名の無い行）があれば列を決める。数値列が1列ならそれ、2列以上なら当期の見出しの列。
        let width = rows.map(\.count).max() ?? 0
        guard width >= 2 else { return nil }
        // 見出しは最初のデータ行の直前の、数値の無い行（単位だけの行より後ろ）。
        func isData(_ row: [String]) -> Bool { row.dropFirst().contains { amount($0) != nil } }
        guard let firstData = rows.firstIndex(where: isData) else { return nil }
        let headerIndex = rows[..<firstData].lastIndex { !isData($0) }
        let dataRows = rows.enumerated()
            .filter { $0.offset != headerIndex && isData($0.element) }
            .map(\.element)
        let numericColumns = (1..<width).filter { column in
            dataRows.contains { column < $0.count && amount($0[column]) != nil }
        }
        let valueColumn: Int
        var picked = false
        if numericColumns.count == 1 {
            valueColumn = numericColumns[0]
        } else {
            guard let headerIndex else { return nil }
            let header = rows[headerIndex]
            let current = numericColumns.filter { column in
                column < header.count && currentHeaderKeywords.contains(where: compact(header[column]).contains)
                    && !priorHeaderKeywords.contains(where: compact(header[column]).contains)
            }
            guard current.count == 1 else { return nil }
            valueColumn = current[0]
            picked = true
        }
        var labels: [String] = []
        var amounts: [Double] = []
        for row in dataRows {
            guard let label = row.first, !compact(label).isEmpty else { return nil }
            let cell = valueColumn < row.count ? row[valueColumn] : ""
            guard let value = amount(cell) else { return nil }
            labels.append(label)
            amounts.append(value * unit)
        }
        return build(labels: labels, amounts: amounts, unit: unit, pickedCurrentColumn: picked)
    }

    /// 地域と合計に分け、地域の和を合計と照らす。小計（「海外計」等）は和が合うときだけ落とす。
    private static func build(labels: [String], amounts: [Double], unit: Double, pickedCurrentColumn: Bool) -> Parsed? {
        var entries: [Entry] = []
        var total: Double?
        for (label, value) in zip(labels, amounts) {
            let key = stripNoteMarks(compact(label))
            if totalLabels.contains(key) {
                guard total == nil else { return nil }
                total = value
                continue
            }
            // 内数（うち米国）は和に入れない。
            if key.hasPrefix("うち") || key.hasPrefix("(うち") || key.hasPrefix("（うち") { continue }
            entries.append(Entry(label: label, value: value))
        }
        let regionHits = entries.filter { entry in
            Xbrl.segmentGeographyLabelKeywordsJa.contains(where: compact(entry.label).contains)
        }
        guard entries.count >= 2, regionHits.count >= 2 else { return nil }
        if let total {
            func matches(_ list: [Entry]) -> Bool {
                abs(list.reduce(0) { $0 + $1.value } - total) <= Double(list.count) * unit
            }
            if !matches(entries) {
                let withoutSubtotals = entries.filter { !stripNoteMarks(compact($0.label)).hasSuffix("計") }
                guard withoutSubtotals.count >= 2, matches(withoutSubtotals) else { return nil }
                entries = withoutSubtotals
            }
        }
        return Parsed(entries: entries, total: total, pickedCurrentColumn: pickedCurrentColumn)
    }

    // MARK: - geography payload へ付ける

    /// geography の payload に地域資産のセルを付ける。地域名が1つも合わなければ付けない。
    static func attach(_ table: Table, to payload: BreakdownSnapshotPayload) -> BreakdownSnapshotPayload {
        var out = payload
        var byKey: [String: Double] = [:]
        for entry in table.parsed.entries { byKey[labelKey(entry.label)] = entry.value }
        var matched = Set<String>()
        for index in out.rows.indices {
            let row = out.rows[index]
            let key = [labelKey(row.labelRaw), labelKey(row.label)].first { byKey[$0] != nil }
            guard let key, let value = byKey[key] else { continue }
            out.rows[index].assets = value
            matched.insert(key)
        }
        guard !matched.isEmpty else { return payload }
        if matched.count < byKey.count, !out.warnings.contains(warningUnmatchedRows) {
            out.warnings.append(warningUnmatchedRows)
        }
        let denominator = table.parsed.total ?? table.parsed.entries.reduce(0) { $0 + $1.value }
        out.assets = CapexMetricTotalsPayload(
            denominator: denominator,
            denominatorTag: table.parsed.total == nil ? denominatorTagRowSum : denominatorTagTableTotal)
        out.assetsMetric = table.metric
        return out
    }

    // MARK: - 文字列

    static func labelKey(_ text: String) -> String {
        stripNoteMarks(compact(text))
    }

    private static func compact(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    }

    /// 「日本(注1)」「米国※」「欧州 (注)」の注記番号を落とす。
    private static func stripNoteMarks(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "※", with: "")
        t = t.replacingOccurrences(of: #"[(（]注\d*[)）]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\d*$"#, with: "", options: .regularExpression)
        return t
    }

    private static func amount(_ cell: String) -> Double? {
        let t = compact(cell)
        guard !t.isEmpty else { return nil }
        if RevenueRecognitionCandidates.dashCells.contains(t) { return 0 }
        return XBRLUtils.parseHtmlNumber(t)
    }

    /// 数値の無い行で、2セル以上に文字がある（見出し行）。
    private static func isLabelRow(_ row: [String]) -> Bool {
        let rest = row.dropFirst()
        return !rest.contains { amount($0) != nil } && rest.filter { !compact($0).isEmpty }.count >= 2
    }

    private static func cleaned(_ grid: [[String]]) -> [[String]] {
        grid.filter { row in row.contains { !compact($0).isEmpty } }
    }

    private static func unitInHeader(_ grid: [[String]]) -> Double? {
        for row in grid.prefix(2) {
            for cell in row {
                if let unit = CompanyRelationsExtractor.amountUnitMultiplier(in: cell) { return unit }
            }
        }
        return nil
    }
}
