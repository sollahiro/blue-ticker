// US-GAAP HTML財務諸表フィールド抽出
// Python の blue_ticker/analysis/usgaap/{html_fields,gross_profit,interest_expense}.py 相当
//
// US-GAAP 有価証券報告書は連結 P/L・BS の値が XBRL 数値タグではなく
// iXBRL HTML テーブルにのみ存在するため、HTML から仮想タグ（USGAAP_HTML_*）を生成して
// FieldSet に注入する。

import Foundation
import SwiftSoup

// MARK: - 財務諸表 HTML テーブル共通ヘルパー

/// 「前期/当期」列ヘッダーの検出と、ラベル行の数値セル取得。
/// US-GAAP P/L テーブルと IFRS リース負債 HTML 抽出で共有する。
enum HtmlFinancialTable {

    static let headerMarkers = ["前連結", "当連結", "前中間", "当中間", "前期", "当期", "第"]

    private static let fiscalTermRegex = try! NSRegularExpression(pattern: "第\\d+期")

    private static func matchesFiscalTerm(_ text: String) -> Bool {
        fiscalTermRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// テーブルのヘッダー行から前期・当期の列オフセットを検出する（colspan 考慮）。
    static func detectColumnIndexes(rows: [Element]) -> (prior: Int?, current: Int?) {
        var priorIdx: Int?
        var currentIdx: Int?
        for row in rows {
            guard let cells = (try? row.select("td, th"))?.array() else { continue }
            let texts = cells.map { (try? $0.text(trimAndNormaliseWhitespace: true)) ?? "" }
            guard texts.contains(where: { t in headerMarkers.contains(where: { t.contains($0) }) }) else { continue }
            var colOffset = 0
            for (cell, text) in zip(cells, texts) {
                let span = XBRLUtils.parseHtmlIntAttribute(cell, "colspan")
                if text.contains("当連結") || text.contains("当中間")
                    || (text.contains("当期") && !text.contains("前期")) {
                    currentIdx = colOffset
                } else if text.contains("前連結") || text.contains("前中間") || text.contains("前期") {
                    priorIdx = colOffset
                } else if matchesFiscalTerm(text) {
                    if priorIdx == nil { priorIdx = colOffset } else { currentIdx = colOffset }
                }
                colOffset += span
            }
            if currentIdx != nil { break }
        }
        return (priorIdx, currentIdx)
    }

    /// ラベル行の数値セルを (セル index, 値) で返す（先頭ラベルセルを除く）。
    static func numericCells(_ cells: [Element]) -> [(idx: Int, value: Double)] {
        var result: [(idx: Int, value: Double)] = []
        for (i, c) in cells.enumerated() where i > 0 {
            let text = (try? c.text(trimAndNormaliseWhitespace: true)) ?? ""
            if let v = XBRLUtils.parseHtmlNumber(text) {
                result.append((i, v))
            }
        }
        return result
    }

    /// 数値セル列から target 列に最も近い値を返す（距離 2 まで。同距離なら右側優先）。
    static func nearestValue(to target: Int, in numerics: [(idx: Int, value: Double)]) -> Double? {
        var bestVal: Double?
        var bestDist = Int.max
        var bestIdx = -1
        for (i, v) in numerics {
            let d = abs(i - target)
            if d < bestDist || (d == bestDist && i > bestIdx) {
                bestDist = d
                bestVal = v
                bestIdx = i
            }
        }
        return bestDist <= 2 ? bestVal : nil
    }
}

// MARK: - US-GAAP HTML フィールド抽出

enum USGAAPHtml {

    // US-GAAP 連結財政状態計算書 HTML → 仮想タグマッピング
    static let bsLabelMap: [String: String] = [
        "流動資産合計":                             "USGAAP_HTML_CurrentAssets",
        "有形固定資産合計":                         "USGAAP_HTML_PPENet",   // 富士フイルム形式
        "有形固定資産":                             "USGAAP_HTML_PPENet",   // キヤノン形式（節番号付き「Ⅳ　有形固定資産」）
        "投資及び長期債権合計":                     "USGAAP_HTML_InvestmentsLTReceivables",
        "その他の資産合計":                         "USGAAP_HTML_OtherNCA",
        "流動負債合計":                             "USGAAP_HTML_CurrentLiabilities",
        "固定負債合計":                             "USGAAP_HTML_NonCurrentLiabilities",
        "負債合計":                                 "USGAAP_HTML_TotalLiabilities",
        "純資産合計":                               "USGAAP_HTML_NetAssets",
        // PPE 内訳（取得原価ベース。土地・建設仮勘定は非償却のため取得原価 = 帳簿価額）
        "土地":                                     "USGAAP_HTML_Land",
        "建設仮勘定":                               "USGAAP_HTML_ConstructionInProgress",
        // PPE 建物・機械（取得原価。富士フイルム形式・キヤノン形式で節番号付きも substring でヒット）
        "建物及び構築物":                           "USGAAP_HTML_BuildingsGross",
        "機械装置及び備品":                         "USGAAP_HTML_MachineryGross",   // キヤノン形式
        "機械装置及びその他の有形固定資産":         "USGAAP_HTML_MachineryGross",   // 富士フイルム形式
        // オペレーティング・リース負債（ASC 842）。節番号・中点の有無を問わず substring でヒット
        "短期オペレーティング":                     "USGAAP_HTML_LeaseLiabilitiesCurrent",
        "長期オペレーティング":                     "USGAAP_HTML_LeaseLiabilitiesNonCurrent",
        // 富士フイルム形式 IBD ラベル
        "社債及び短期借入金":                       "USGAAP_HTML_IBDCurrent",
        "社債及び長期借入金":                       "USGAAP_HTML_IBDNonCurrent",
        // キヤノン形式 IBD ラベル（"長期債務" は CF 文中にも現れるため章番号付きで特定する）
        "短期借入金及び１年以内に返済する長期債務合計": "USGAAP_HTML_IBDCurrent",
        "Ⅱ　長期債務":                          "USGAAP_HTML_IBDNonCurrent",
        // 売掛金（キヤノン形式: "売上債権"、富士フイルム形式: "(4)信用損失引当金" → 最長一致でヒット）
        "売上債権":                              "USGAAP_HTML_AccountsReceivable",
        "信用損失引当金":                        "USGAAP_HTML_AccountsReceivable",
        "棚卸資産":                              "USGAAP_HTML_Inventory",
        // 買掛金（キヤノン形式: "買入債務"、富士フイルム形式: "(3) 関連会社等に対する債務"）
        "買入債務":                              "USGAAP_HTML_AccountsPayable",
        "関連会社等に対する債務":                "USGAAP_HTML_AccountsPayable",
    ]

    // US-GAAP 連結損益計算書 HTML → 仮想タグマッピング（法人税を除く）
    // 法人税は「Ⅴ　法人税等」節ヘッダーを基準にセクション内検索で取得する（extractIncomeTaxSection）。
    // CF計算書ラベル（財務活動）も同一ファイル 0105010 内に存在するためここで共に定義する。
    static let plLabelMap: [String: String] = [
        "販売費及び一般管理費":         "USGAAP_HTML_SGA",
        "営業利益":                    "USGAAP_HTML_OperatingIncome",
        "税金等調整前当期純利益":       "USGAAP_HTML_PreTaxIncome",
        "税引前当期純利益":             "USGAAP_HTML_PreTaxIncome",
        "税金等調整前当期純損失":       "USGAAP_HTML_PreTaxIncome",
        "法人税等合計":                "USGAAP_HTML_IncomeTax",
        "法人税、住民税及び事業税":     "USGAAP_HTML_IncomeTaxCurrent",
        "法人税等調整額":              "USGAAP_HTML_IncomeTaxDeferred",
        // CF計算書・財務活動
        // 配当金: キヤノン形式 "配当金の支払額"、富士フイルム形式 "配当金支払額"（の なし）
        "配当金の支払額":              "USGAAP_HTML_DividendPaidCF",
        "配当金支払額":                "USGAAP_HTML_DividendPaidCF",
        // 自己株式CF は株主資本変動計算書と同ラベルが衝突するため extractCFTreasuryStockFromCF で個別抽出
    ]

    private static let romanPrefixRegex = try! NSRegularExpression(
        pattern: "^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ\\s　]+"
    )
    private static let romanStartRegex = try! NSRegularExpression(
        pattern: "^[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ]"
    )

    /// ローマ数字節番号（「Ⅴ　」等）のプレフィックスを除去して本文ラベルを返す。
    static func stripSectionPrefix(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = romanPrefixRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    private static func startsWithRoman(_ text: String) -> Bool {
        romanStartRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: ファイル探索・パース

    /// 年次(asr)は 0105010＝第５経理の状況、半期(q2r)は 0104010＝第４経理の状況
    private static func findStatementHtml(in xbrlDir: URL) -> URL? {
        XBRLUtils.findHtmlByPrefix(in: xbrlDir, prefix: "0105010")
            ?? XBRLUtils.findHtmlByPrefix(in: xbrlDir, prefix: "0104010")
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseDocument(_ url: URL) -> Document? {
        guard let content = readText(url) else { return nil }
        return try? SwiftSoup.parse(content)
    }

    // MARK: BS フィールド

    /// US-GAAP 連結財政状態計算書 HTML（0105010_*）から FieldSet を生成する。値の単位は円。
    static func parseBSFields(in xbrlDir: URL) -> FieldSet {
        guard let bsHtml = findStatementHtml(in: xbrlDir),
              let soup = parseDocument(bsHtml) else { return [:] }
        return XBRLUtils.extractHtmlLabels(from: soup, labelMap: bsLabelMap)
    }

    // MARK: P/L フィールド

    /// US-GAAP 連結損益計算書 HTML から FieldSet を生成する。値の単位は円。
    ///
    /// US-GAAP 有価証券報告書では以下のように情報が分散する。
    /// - 税引前利益: 0101010（過去5ヶ年の主要指標表）
    /// - 法人税等:   0105010（連結財務諸表）の「Ⅴ　法人税等」節
    /// - 営業利益等: 0105010（同上）
    ///
    /// 先にヒットしたファイルの値を優先し、複数ファイルをマージする。
    static func parsePLFields(in xbrlDir: URL) -> FieldSet {
        var merged: FieldSet = [:]

        if let html0101010 = XBRLUtils.findHtmlByPrefix(in: xbrlDir, prefix: "0101010"),
           let soup = parseDocument(html0101010) {
            for (vtag, fv) in XBRLUtils.extractHtmlLabels(from: soup, labelMap: plLabelMap) where merged[vtag] == nil {
                merged[vtag] = fv
            }
        }

        if let html = findStatementHtml(in: xbrlDir),
           let soup = parseDocument(html) {
            // 法人税はセクション特定で取得（ラベル部分マッチによる誤拾いを防ぐ）
            if merged["USGAAP_HTML_IncomeTax"] == nil, let taxFV = extractIncomeTaxSection(soup) {
                merged["USGAAP_HTML_IncomeTax"] = taxFV
            }
            for (vtag, fv) in XBRLUtils.extractHtmlLabels(from: soup, labelMap: plLabelMap) where merged[vtag] == nil {
                merged[vtag] = fv
            }
            // 自己株式CF: ローマ数字始まり（株主資本変動計算書）と衝突するため専用関数で抽出
            if merged["USGAAP_HTML_CFTreasuryStock"] == nil, let cfts = extractCFTreasuryStockFromCF(soup) {
                merged["USGAAP_HTML_CFTreasuryStock"] = cfts
            }
            // 株主資本等変動計算書から配当金SS（US-GAAP専用）
            if merged["USGAAP_HTML_DividendSS"] == nil, let divFV = extractDividendSSFromEquityStatement(soup) {
                merged["USGAAP_HTML_DividendSS"] = divFV
            }
        }

        return merged
    }

    /// CF計算書の財務活動セクションから自己株式取得額を抽出する（US-GAAP専用）。
    ///
    /// 株主資本等変動計算書にも「自己株式取得」行が存在し、かつそちらが HTML 上で先に出現するため、
    /// ローマ数字始まり行（株主資本変動計算書の節番号 Ⅳ, ⅩⅢ 等）をスキップして CF 行のみを対象にする。
    private static func extractCFTreasuryStockFromCF(_ soup: Document) -> FieldValue? {
        guard let rows = try? soup.select("tr") else { return nil }
        for row in rows {
            guard let cells = (try? row.select("td, th"))?.array(), !cells.isEmpty else { continue }
            let first = (try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? ""
            guard !startsWithRoman(first) else { continue }
            let normalized = first
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{3000}", with: " ")
            guard normalized.contains("自己株式の取得及び売却") || normalized.contains("自己株式取得") else { continue }
            let allNums = cells.dropFirst()
                .compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
                .compactMap { XBRLUtils.parseHtmlNumber($0) }
            let financial = allNums.filter { abs($0) >= 200 }
            let found = financial.isEmpty ? allNums : financial
            guard !found.isEmpty else { continue }
            return FieldValue(
                current: found.last! * Financial.millionYen,
                prior: found.count >= 2 ? found[found.count - 2] * Financial.millionYen : nil
            )
        }
        return nil
    }

    /// 株主資本等変動計算書から「当社株主への配当金」を抽出する（US-GAAP専用）。
    ///
    /// 前期・当期それぞれの行が存在するため、最後の行の値（当期分）を採用する。
    /// 値は百万円単位の負値（キャッシュアウト）で返す。
    private static func extractDividendSSFromEquityStatement(_ soup: Document) -> FieldValue? {
        var lastValue: Double? = nil
        guard let rows = try? soup.select("tr") else { return nil }
        for row in rows {
            guard let cells = (try? row.select("td, th"))?.array(), !cells.isEmpty else { continue }
            let first = (try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? ""
            guard first.contains("当社株主への") else { continue }
            let nums = cells.dropFirst()
                .compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
                .compactMap { XBRLUtils.parseHtmlNumber($0) }
                .filter { abs($0) >= 200 }
            if let v = nums.last { lastValue = v }
        }
        guard let v = lastValue else { return nil }
        return FieldValue(current: v * Financial.millionYen, prior: nil)
    }

    /// 「Ⅴ　法人税等」節から法人税等合計（円）を抽出する。
    ///
    /// 節ヘッダー行に数値があればそれを使い、ない場合は節内の最初の「合計」行を使う。
    /// 次のローマ数字節に達したら探索を終了する。
    private static func extractIncomeTaxSection(_ soup: Document) -> FieldValue? {
        var inTaxSection = false
        guard let rows = try? soup.select("tr") else { return nil }
        for row in rows {
            guard let cells = (try? row.select("td, th"))?.array() else { continue }
            let texts = cells.map { (try? $0.text(trimAndNormaliseWhitespace: true)) ?? "" }
            guard let t0 = texts.first else { continue }

            if stripSectionPrefix(t0) == "法人税等" {
                inTaxSection = true
                if let fv = financialTotals(texts) { return fv }
                continue
            }

            if inTaxSection {
                if startsWithRoman(t0) { break }
                if t0 == "合計", let fv = financialTotals(texts) { return fv }
            }
        }
        return nil
    }

    /// 行テキストから財務金額（百万円単位で >= 200）を抽出し当期/前期の FieldValue を返す。
    private static func financialTotals(_ texts: [String]) -> FieldValue? {
        let nums = texts.dropFirst().compactMap { XBRLUtils.parseHtmlNumber($0) }
        let financial = nums.filter { abs($0) >= 200 }
        guard !financial.isEmpty else { return nil }
        return FieldValue(
            current: financial.last! * Financial.millionYen,
            prior: financial.count >= 2 ? financial[financial.count - 2] * Financial.millionYen : nil
        )
    }

    // MARK: 売上総利益

    /// US-GAAP企業の連結損益計算書(0105010)HTMLから売上総利益を抽出する。値の単位は円。
    static func extractGrossProfit(in xbrlDir: URL) -> FieldValue? {
        guard let file = findStatementHtml(in: xbrlDir),
              let content = readText(file),
              content.contains("売上総利益"),
              let soup = try? SwiftSoup.parse(content),
              let tables = try? soup.select("table") else { return nil }

        for table in tables {
            guard let tableText = try? table.text(), tableText.contains("売上総利益") else { continue }
            guard let rows = (try? table.select("tr"))?.array(), !rows.isEmpty else { continue }
            let (priorIdx, currentIdx) = HtmlFinancialTable.detectColumnIndexes(rows: rows)

            for row in rows {
                guard let cells = (try? row.select("td, th"))?.array(), !cells.isEmpty else { continue }
                let label = (try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? ""
                guard label.contains("売上総利益") else { continue }

                let numerics = HtmlFinancialTable.numericCells(cells)
                guard numerics.count >= 2 else { continue }

                let priorVal: Double?
                let currentVal: Double?
                if let p = priorIdx, let c = currentIdx {
                    priorVal = HtmlFinancialTable.nearestValue(to: p, in: numerics)
                    currentVal = HtmlFinancialTable.nearestValue(to: c, in: numerics)
                } else {
                    priorVal = numerics[0].value
                    currentVal = numerics.last!.value
                }

                return FieldValue(
                    current: currentVal.map { $0 * Financial.millionYen },
                    prior: priorVal.map { $0 * Financial.millionYen }
                )
            }
        }
        return nil
    }

    // MARK: 支払利息

    /// US-GAAP企業の連結損益計算書(0105010)HTMLから支払利息を抽出する。値の単位は円（絶対値）。
    static func extractInterestExpense(in xbrlDir: URL) -> FieldValue? {
        guard let file = findStatementHtml(in: xbrlDir),
              let content = readText(file),
              content.contains("支払利息"),
              let soup = try? SwiftSoup.parse(content),
              let tables = try? soup.select("table") else { return nil }

        for table in tables {
            guard let tableText = try? table.text(), tableText.contains("支払利息") else { continue }
            guard let rows = (try? table.select("tr"))?.array(), !rows.isEmpty else { continue }
            let (priorIdx, currentIdx) = HtmlFinancialTable.detectColumnIndexes(rows: rows)

            for row in rows {
                guard let cells = (try? row.select("td, th"))?.array(), !cells.isEmpty else { continue }
                let label = (try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? ""
                guard label.contains("支払利息") else { continue }
                guard !["受取", "未払"].contains(where: { label.contains($0) }) else { continue }

                let numerics = HtmlFinancialTable.numericCells(cells)
                guard !numerics.isEmpty else { continue }

                let priorVal: Double?
                let currentVal: Double?
                if let p = priorIdx, let c = currentIdx {
                    priorVal = HtmlFinancialTable.nearestValue(to: p, in: numerics)
                    currentVal = HtmlFinancialTable.nearestValue(to: c, in: numerics)
                } else {
                    priorVal = numerics.count >= 2 ? numerics[0].value : nil
                    currentVal = numerics.last!.value
                }

                guard currentVal != nil || priorVal != nil else { continue }

                return FieldValue(
                    current: currentVal.map { abs($0) * Financial.millionYen },
                    prior: priorVal.map { abs($0) * Financial.millionYen }
                )
            }
        }
        return nil
    }
}
