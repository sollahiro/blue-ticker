// 連結附属明細表「借入金等明細表」からの有利子負債抽出
//
// 連結BSに有利子負債の数値タグが存在しない企業（リース債務が明細表のみに記載される等）向けの
// フォールバック。明細表は「区分 | 当期首残高 | 当期末残高 | 平均利率 | 返済期限」の固定列で、
// 当期首残高=前期末、当期末残高=当期末。最終行の「合計」で有利子負債総額を確定する。

import Foundation
import SwiftSoup

enum BorrowingsSchedule {

    /// 明細表1行分。`averageInterestRatePercent` は「平均利率（％）」列の生数値（例: 0.80 は年0.80%）。
    /// 開示されない行（リース債務の一部・合計行等）は「－」「――」表記のため nil。
    struct Row {
        let label: String
        let current: Double?
        let prior: Double?
        let averageInterestRatePercent: Double?
    }

    /// リース債務行は「リース負債（流動/非流動）」へ正規化し、コードベース全体の表示ラベルに揃える。
    /// それ以外の区分（短期借入金・社債・長期借入金等）は明細表の表記をそのまま使う。
    private static func displayLabel(for normalizedLabel: String) -> String {
        guard normalizedLabel.contains("リース") else { return normalizedLabel }
        // 「1年以内に返済予定のものを除く」は非流動。"1年以内" を含むため除外判定を先に行う。
        if normalizedLabel.contains("除く") { return "リース負債（非流動）" }
        let currentMarkers = ["1年以内", "1年内", "１年以内", "１年内", "流動"]
        let isCurrent = currentMarkers.contains { normalizedLabel.contains($0) }
        return isCurrent ? "リース負債（流動）" : "リース負債（非流動）"
    }

    /// フィルタ通過前の1行分（インデント深さつき）。`label` は displayLabel 適用前の生ラベル。
    private struct RawRow {
        let label: String
        let indent: Int
        let current: Double?
        let prior: Double?
        let rate: Double?
    }

    /// ラベルの前後の全角/半角スペース・nbsp を除去する（"合計"／"計" 判定・displayLabel 適用の前処理）。
    private static func normalizeLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
    }

    /// ラベルセルの先頭 `<p>` からインデント深さを読む。実データ検証（2026-08-02）: 階層表現は
    /// 会社により2通りある。① CSS `margin-left`（例: あおぞら銀行、pxをそのまま深さに使う）
    /// ② 全角/半角スペース・nbsp をラベル文字列先頭に付けるだけ（例: コンコルディア「　　借入金」、
    /// しずおかFG「　借入金」。`margin-left` が無い/0 の場合はこちらにフォールバックする）。
    /// `<p>` が無い（インデント情報自体が無い）行は 0（トップレベル）として扱う。
    private static func indentLevel(of p: Element?) -> Int {
        guard let p else { return 0 }
        if let style = try? p.attr("style"),
           let regex = try? NSRegularExpression(pattern: "margin-left:\\s*(\\d+)px"),
           let match = regex.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
           let numRange = Range(match.range(at: 1), in: style),
           let px = Int(style[numRange]), px > 0 {
            return px
        }
        let raw = (try? p.text(trimAndNormaliseWhitespace: false)) ?? ""
        return raw.prefix { $0 == " " || $0 == "\u{3000}" || $0 == "\u{00A0}" }.count
    }

    /// 「区分 | 当期首残高 | 当期末残高 | 平均利率 | 返済期限」表を1行ずつ読む共通処理
    /// （`extract`・`extractRows` 両方から使う。表探索・合計行判定・合算フォールバックを1箇所に集約）。
    ///
    /// 実データ検証（2026-08-02）: 残高列の単位（「当期首残高（百万円）」等ヘッダー表記）は会社規模で
    /// 揺れる（レーザーテック S100JRT9 等は千円、SOMPO S100R1LR・神戸製鋼所 S100QYHM 等は百万円）。
    /// 単位を検出せず一律 `Financial.millionYen` で換算すると千円表記の会社は1000倍に水増しされる
    /// （既存 golden test の 24,202,000,000 円は誤り。実際は千円ヘッダーにつき 24,202,000 円）。
    /// `parseCapexTable`/`parseIssuedSharesTable` と同じくヘッダー文言から都度判定する。
    ///
    /// 実データ検証（2026-08-03、ユーザーレビューで発見）: 銀行・金融持株会社系は「借用金」（カテゴリ
    /// 小計）の下に「再割引手形」「借入金」（内訳の実体行）がインデント付きで並ぶ階層表を使う
    /// （あおぞら銀行・コンコルディア・しずおかFG・ふくおかFG・T&D等）。インデントを見ずに全行を
    /// フラットに合算すると、小計行と内訳行が二重計上される。`indentLevel` で深さを読み、次の行が
    /// より深い（＝自分の内訳が続く）行はカテゴリ小計として除外する。
    ///
    /// 実データ検証（2026-08-03）: ダイキン・T&D等の「その他有利子負債」は、内訳（コマーシャル・
    /// ペーパー／割賦未払金等）が別 `<tr>` ではなく同一セル内に複数 `<p>` として縦積みされる（カテゴリ
    /// 名の `<p>` に値が無く、後続の `<p>` に内訳ごとの値が並ぶ）。この場合はラベル・値それぞれの
    /// `<p>` 配列を同じ添字で zip し、1行を複数の内訳行に分解する（"その他有利子負債 コマーシャル・
    /// ペーパー(１年以内) 割賦未払金(１年以内) 割賦未払金(１年超)" のようにラベルが連結され数値も
    /// 混ざっていたバグの修正）。
    private static func parseJGaapScheduleTable(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let html = XBRLUtils.extractTextblockHtml(
                in: xbrlDir, textblockTag: Xbrl.borrowingsScheduleTextblockTag),
              let soup = try? SwiftSoup.parse(html),
              let tables = (try? soup.select("table"))?.array() else { return nil }

        // 「計」を含む表が本体明細表（"合計" 表記の会社も "計" を含むため、この1条件で両対応）。
        // 後続の返済予定額の別表を除外するために選別する。
        let table = tables.first { ((try? $0.text()) ?? "").contains("計") } ?? tables.first
        guard let table, let rows = (try? table.select("tr"))?.array() else { return nil }

        let tableText = (try? table.text()) ?? ""
        let scale: Double = tableText.contains("千円") ? 1_000
            : tableText.contains("億円") ? 100_000_000
            : Financial.millionYen

        var rawRows: [RawRow] = []
        var totalCurrent: Double?
        var totalPrior: Double?

        rowLoop: for row in rows {
            guard let cells = (try? row.select("td, th"))?.array(), cells.count >= 3 else { continue }
            let labelPs = (try? cells[0].select("p"))?.array() ?? []

            if labelPs.count > 1 {
                // カテゴリ名+内訳が同一セルに縦積みされた行を、内訳ごとの行に分解する。
                let priorPs = (try? cells[1].select("p"))?.array() ?? []
                let currentPs = (try? cells[2].select("p"))?.array() ?? []
                let ratePs = cells.count >= 4 ? (try? cells[3].select("p"))?.array() ?? [] : []
                for i in labelPs.indices {
                    let label = normalizeLabel((try? labelPs[i].text(trimAndNormaliseWhitespace: true)) ?? "")
                    guard !label.isEmpty else { continue }
                    let prior = i < priorPs.count ? XBRLUtils.parseTextblockCellValue(try? priorPs[i].text()) : nil
                    let current = i < currentPs.count ? XBRLUtils.parseTextblockCellValue(try? currentPs[i].text()) : nil
                    // カテゴリ名自体の行（値なし）を除外する。
                    guard current != nil || prior != nil else { continue }
                    let rate = i < ratePs.count ? XBRLUtils.parseTextblockCellValue(try? ratePs[i].text()) : nil
                    // 縦積みされた内訳行は常に末端（それ以上の階層を持たない）として扱う。
                    rawRows.append(RawRow(label: label, indent: Int.max, current: current, prior: prior, rate: rate))
                }
                continue
            }

            let label = normalizeLabel((try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? "")
            guard !label.isEmpty else { continue }

            let prior = XBRLUtils.parseTextblockCellValue(try? cells[1].text())
            let current = XBRLUtils.parseTextblockCellValue(try? cells[2].text())
            // 区分ヘッダ・「該当事項はありません」等の非数値行を除外する。
            guard current != nil || prior != nil else { continue }
            let rate = cells.count >= 4 ? XBRLUtils.parseTextblockCellValue(try? cells[3].text()) : nil

            if label == "合計" || label == "計" {
                totalCurrent = current.map { $0 * scale }
                totalPrior = prior.map { $0 * scale }
                break rowLoop  // 合計以降は返済予定額の別表
            }
            rawRows.append(RawRow(label: label, indent: indentLevel(of: labelPs.first), current: current, prior: prior, rate: rate))
        }

        // 次の行がより深いインデントを持つ行（＝内訳がぶら下がるカテゴリ小計）は除外し、二重計上を防ぐ。
        var components: [Row] = []
        for i in rawRows.indices {
            if i + 1 < rawRows.count, rawRows[i + 1].indent > rawRows[i].indent { continue }
            let r = rawRows[i]
            components.append(Row(
                label: displayLabel(for: r.label),
                current: r.current.map { $0 * scale },
                prior: r.prior.map { $0 * scale },
                averageInterestRatePercent: r.rate
            ))
        }

        // 合計行が無い様式ではコンポーネントを合算する。
        if totalCurrent == nil && totalPrior == nil {
            let cs = components.compactMap { $0.current }
            let ps = components.compactMap { $0.prior }
            totalCurrent = cs.isEmpty ? nil : cs.reduce(0, +)
            totalPrior = ps.isEmpty ? nil : ps.reduce(0, +)
        }

        guard totalCurrent != nil || totalPrior != nil else { return nil }
        return (components, totalCurrent, totalPrior)
    }

    /// IFRS連結企業向け「社債及び借入金」／「有利子負債」注記からの抽出。J-GAAP附属明細表タグが
    /// 無い、またはあっても財務諸表等規則の適用除外でクロスリファレンス文のみ（表なし）の場合に
    /// `parseTable` からフォールバックとして呼ばれる。
    ///
    /// 実データ検証（2026-08-03、ユーザーレビューで発見。KDDI S100R0PR・HOYA S100VW2P）:
    /// J-GAAP附属明細表と列構成が異なり「区分 | 前連結会計年度 | 当連結会計年度 | 平均利率(注) |
    /// 返済期限」で、会社によって列間に罫線用の空白セル（幅6px程度のスペーサー）が挟まる
    /// （KDDIはスペーサーあり、HOYAはスペーサーなし）。固定インデックスでは崩れるため、
    /// ヘッダー行のセルテキスト（"前"／"当"／"利率"を含むか）から列位置を都度解決する。
    ///
    /// 階層構造も異なる。KDDIは「非流動」「流動」の2区分見出し（値なし）の下に実体行が並び、
    /// 各区分の末尾にセクション小計「　小計」（nbsp+"小計"）が付く。HOYAは区分見出しが無く実体行
    /// のみの後、真の合計「有利子負債合計」に続けて参考内訳「非流動負債合計」「流動負債合計」が
    /// 続く。"小計"（完全一致）は常にセクション内訳のため除外して読み進め、それ以外で"計"に一致
    /// するか"合計"で終わるラベル（"有利子負債合計"等）に達したら真の合計として確定し打ち切る。
    /// こうしないとHOYAの参考内訳がコンポーネントに紛れ込み二重計上になる。
    private static func parseIFRSNotesTable(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsBondsAndBorrowingsTextblockTag)
            ?? XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsInterestBearingLiabilitiesTextblockTag)
            ?? XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsBorrowingsOnlyTextblockTag)
        guard let html, let soup = try? SwiftSoup.parse(html),
              let tables = (try? soup.select("table"))?.array() else { return nil }

        // 実データ検証（2026-08-03）: 平均利率・返済期限のどちらも列に持たない会社もある
        // （村田製作所 S100TSIJ の IFRS初度適用年度は「区分｜移行日｜前連結会計年度末｜
        // 当連結会計年度末」のみ）。「前」「当」を含む表を残高内訳表とみなす。ロールフォワード表
        // （期首残高／キャッシュ・フロー／期末残高等）は「前」「当」を含まないため誤選択しない。
        // 同一注記内に銘柄別の社債明細表（会社名・銘柄・発行年月日等、こちらも前/当を含む）が
        // 続く／先行することがある（味の素 S100VXJA は銘柄別表が本体表より先に出現し、単純な
        // `first` では誤って銘柄別表を拾ってしまうことを実データで確認）。銘柄別表は "銘柄" 列を
        // 持つため、これを含む表は除外する。
        //
        // ソフトバンクグループ S100QZOM 実データ検証（2026-08-03）: 列見出しが「前」「当」ではなく
        // 西暦日付そのもの（"2022年３月31日"／"2023年３月31日"）の会社がある。「前」「当」で
        // 見つからない場合は日付パターンが2つ以上ある表にフォールバックする。
        let jpDatePattern = try? NSRegularExpression(pattern: "\\d{4}年\\d{1,2}月\\d{1,2}日")
        func jpDateMatchCount(_ text: String) -> Int {
            guard let jpDatePattern else { return 0 }
            return jpDatePattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        let table = tables.first {
            let t = (try? $0.text()) ?? ""
            guard !t.contains("銘柄") else { return false }
            return (t.contains("前") && t.contains("当")) || jpDateMatchCount(t) >= 2
        }
        if let table, let result = parseComparisonTable(table) { return result }

        // パナソニックHD S100YETA 実データ検証（2026-08-04）: 専用タグ配下でも「前」「当」を含む表が
        // ロールフォワード表（残高｜変動｜残高、列見出しに前/当を持たない）で、`tables.first` が
        // 誤ってそちらを選んでしまい `parseComparisonTable` が解析対象を見つけられず nil になる。
        // 本体の残高表は見出しアンカー方式または満期構成ペアテーブル形式（会計年度末ごとに別テーブル）
        // であることがあるため、単一テーブル比較が失敗したら同じ soup 内でこれらも試す。
        if let anchored = parseHeadingAnchoredComparisonTable(in: soup) { return anchored }
        return parseMaturityBucketPairTables(in: soup)
    }

    /// 「区分 | 前期 | 当期 | 平均利率 | 返済期限」形の単一テーブルを解析する共通処理。
    /// `parseIFRSNotesTable`（専用タグ配下でテーブル自体を選ぶ）と
    /// `parseHeadingAnchoredComparisonTable`（汎用タグ配下で見出しアンカーによりテーブルを選ぶ）の
    /// 両方から、テーブル選択後の解析ロジックとして共有する。
    private static func parseComparisonTable(_ table: Element) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let trs = (try? table.select("tr"))?.array() else { return nil }

        let tableText = (try? table.text()) ?? ""
        let scale: Double = tableText.contains("千円") ? 1_000
            : tableText.contains("億円") ? 100_000_000
            : Financial.millionYen

        let jpDatePattern = try? NSRegularExpression(pattern: "\\d{4}年\\d{1,2}月\\d{1,2}日")
        func jpDateMatchCount(_ text: String) -> Int {
            guard let jpDatePattern else { return 0 }
            return jpDatePattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }

        // ヘッダー行（前期/当期/平均利率列を持つ行）から列位置を解決する。固定インデックス禁止
        // （スペーサー列の有無で位置が会社ごとに変わるため）。
        var priorIdx: Int?
        var currentIdx: Int?
        var rateIdx: Int?
        var headerRowIndex = -1
        for (i, tr) in trs.enumerated() {
            guard let cells = (try? tr.select("td, th"))?.array() else { continue }
            var p: Int?
            var c: Int?
            var r: Int?
            var dateCols: [Int] = []
            for (j, cell) in cells.enumerated() {
                let text = (try? cell.text(trimAndNormaliseWhitespace: true)) ?? ""
                if p == nil, text.contains("前") { p = j }
                if c == nil, text.contains("当") { c = j }
                if text.contains("利率") { r = j }
                if jpDateMatchCount(text) > 0 { dateCols.append(j) }
            }
            if p == nil, c == nil, dateCols.count >= 2 {
                p = dateCols[0]
                c = dateCols[1]
            }
            if let p, let c {
                priorIdx = p
                currentIdx = c
                rateIdx = r
                headerRowIndex = i
                break
            }
        }
        guard let priorIdx, let currentIdx, headerRowIndex >= 0, headerRowIndex + 1 < trs.count else { return nil }

        var components: [Row] = []
        var totalCurrent: Double?
        var totalPrior: Double?

        rowLoop: for tr in trs[(headerRowIndex + 1)...] {
            guard let cells = (try? tr.select("td, th"))?.array(),
                  cells.count > max(priorIdx, currentIdx) else { continue }
            // 日東電工 S100VYH3 実データ検証（2026-08-03）: ラベル列の前に幅の狭いインデント専用の
            // 空セルが挟まる会社がある。cells[0] が空なら cells[1] をラベルとして使う。
            var label = normalizeLabel((try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? "")
            if label.isEmpty, cells.count > 1 {
                label = normalizeLabel((try? cells[1].text(trimAndNormaliseWhitespace: true)) ?? "")
            }
            guard !label.isEmpty else { continue }

            let prior = XBRLUtils.parseTextblockCellValue(try? cells[priorIdx].text())
            let current = XBRLUtils.parseTextblockCellValue(try? cells[currentIdx].text())
            // 区分見出し（「非流動」「流動」等、値なし）を除外する。
            guard current != nil || prior != nil else { continue }
            let rate = rateIdx.flatMap { idx in
                cells.count > idx ? XBRLUtils.parseTextblockCellValue(try? cells[idx].text()) : nil
            }

            if label == "小計" { continue }   // セクション単位の内訳小計は除外（二重計上防止）
            if label == "計" || label.hasSuffix("合計") {
                totalCurrent = current.map { $0 * scale }
                totalPrior = prior.map { $0 * scale }
                break rowLoop   // 真の合計に到達。以降の参考内訳（非流動負債合計等）は無視する
            }
            components.append(Row(
                label: displayLabel(for: label),
                current: current.map { $0 * scale },
                prior: prior.map { $0 * scale },
                averageInterestRatePercent: rate
            ))
        }

        if totalCurrent == nil && totalPrior == nil {
            let cs = components.compactMap { $0.current }
            let ps = components.compactMap { $0.prior }
            totalCurrent = cs.isEmpty ? nil : cs.reduce(0, +)
            totalPrior = ps.isEmpty ? nil : ps.reduce(0, +)
        }

        guard totalCurrent != nil || totalPrior != nil else { return nil }
        return (components, totalCurrent, totalPrior)
    }

    /// 「社債及び借入金の内訳は次のとおりです」等の見出し段落の直後にある表を、前/当の内訳表として
    /// 解析する。「金融商品に関する注記」汎用タグは為替・信用リスク・公正価値階層等の多数の表を含み、
    /// 単純な「前/当を含む最初の表」では無関係な表（受取手形・売掛金等）を誤選択するため、見出し
    /// テキストをアンカーにして直後の表だけを対象にする。
    /// 実データ検証（2026-08-04: アステラス S100R0I6・丸紅 S100VYGC）。
    private static func parseHeadingAnchoredComparisonTable(in document: Document) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let headingPattern = try? NSRegularExpression(pattern: "社債及び借入金.*(内訳|帳簿価額)"),
              let all = (try? document.getAllElements())?.array() else { return nil }

        var passedHeading = false
        for element in all {
            if !passedHeading {
                guard element.tagName() == "p" else { continue }
                let text = (try? element.text()) ?? ""
                if headingPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    passedHeading = true
                }
                continue
            }
            guard element.tagName() == "table" else { continue }
            return parseComparisonTable(element)
        }
        return nil
    }

    /// 前/当の比較列を持たず、会計年度末ごとに別テーブル（先頭行に単一の和暦/西暦日付、「帳簿価額」列を
    /// 持つ）が並ぶパターンからの抽出。信用リスク・プットオプション等の無関係な行や、会社ごとに構成が
    /// 異なる「合計」「控除」行の混入を避けるため、社債・借入金・リース関連ラベルの帳簿価額のみを拾い、
    /// 合計は自前で積み上げる。実データ検証（2026-08-04: 日立 S100QZT0・ソニーグループ S100QZT6）。
    private static func parseMaturityBucketPairTables(in document: Document) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let allElements = (try? document.getAllElements())?.array(),
              let tables = (try? document.select("table"))?.array(),
              let jpDatePattern = try? NSRegularExpression(pattern: "\\d{4}年\\d{1,2}月\\d{1,2}日") else { return nil }

        // テーブル自身の1行目に日付が無い場合、直前の見出し段落まで遡って日付を探す。
        // パナソニックHD S100YETA・三菱電機 S100YD3V 実データ検証（2026-08-04）: 「①　前連結会計
        // 年度末（2025年３月31日）」のような見出し段落がテーブルの外（直前の兄弟）に置かれ、テーブル
        // 自身は帳簿価額列のみで日付を持たない。パナソニックHDは見出しとテーブルの間に単位表記
        // 「（単位：百万円）」だけの装飾的な1行テーブルが挟まるため、複数行を持つ実データ表に当たる
        // までは透過して遡る（実データ表に達したら別区分の内容のため打ち切り）。
        func precedingDate(before table: Element) -> String? {
            guard let tableIndex = allElements.firstIndex(where: { $0 === table }) else { return nil }
            var i = tableIndex - 1
            var steps = 0
            while i >= 0, steps < 40 {
                let el = allElements[i]
                if el.tagName() == "table" {
                    let rowCount = (try? el.select("tr"))?.array().count ?? 0
                    if rowCount > 1 { return nil }
                } else if el.tagName() == "p" {
                    let text = (try? el.text()) ?? ""
                    if let match = jpDatePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                       let range = Range(match.range, in: text) {
                        return String(text[range])
                    }
                }
                i -= 1
                steps += 1
            }
            return nil
        }

        // 表の「帳簿価額」列から、社債・借入金・リース・コマーシャル・ペーパー関連ラベル（先頭セル
        // 自体がそれらに一致する行のみ）の値を行順を保って読む。公正価値ヘッジ等の注記も「借入金」と
        // いう語を文章内に含むことがある（為替リスク行の説明文等）ため、ラベル列自体で判定し行文章の
        // 部分一致は使わない。三菱電機 S100YD3V 実データ検証（2026-08-04）: 当期のみ「コマーシャル・
        // ペーパー」（短期社債の一種）が別行として出現し、旧フィルタでは取りこぼしていた。
        func bookValues(_ table: Element) -> [(label: String, value: Double)] {
            guard let trs = (try? table.select("tr"))?.array() else { return [] }
            var valueCol: Int?
            var headerRowIndex = -1
            headerSearch: for (i, tr) in trs.enumerated() {
                guard let cells = (try? tr.select("td, th"))?.array() else { continue }
                for (j, cell) in cells.enumerated() {
                    // 荏原製作所 S100XS6E 実データ検証（2026-08-04）: ヘッダーセルが「帳簿」「価額」を
                    // 別々の<p>（列幅が狭いための折り返し）に分けており、text()が間に空白を挟むため
                    // 単純な部分一致では「帳簿価額」に一致しない。空白を除去してから照合する。
                    let text = ((try? cell.text(trimAndNormaliseWhitespace: true)) ?? "").replacingOccurrences(of: " ", with: "")
                    // 日本精工 S100YFE3 実データ検証（2026-08-04）: 同じ「期日別残高」表でも
                    // 「帳簿価額」ではなく「帳簿残高」という表記ゆれがある。
                    if text.contains("帳簿価額") || text.contains("帳簿残高") {
                        valueCol = j
                        headerRowIndex = i
                        break headerSearch
                    }
                }
            }
            guard var valueCol, headerRowIndex >= 0 else { return [] }

            // ソニーグループ S100QZT6 実データ検証（2026-08-04）: ヘッダー行が「項目」列を rowspan で
            // 上段と共有し、ヘッダー行自体には「項目」列のセルが無い（帳簿価額｜加重平均利率｜満期の
            // 3セルのみ）。データ行はラベル列を含む4セルのため、ヘッダー行基準の列位置のままでは
            // 1列ズレる。直後のデータ行のセル数がヘッダー行より多ければ、その差分だけ右にずらす。
            let headerCellCount = (try? trs[headerRowIndex].select("td, th"))?.array().count ?? 0
            if headerRowIndex + 1 < trs.count,
               let firstDataCellCount = (try? trs[headerRowIndex + 1].select("td, th"))?.array().count,
               firstDataCellCount > headerCellCount {
                valueCol += firstDataCellCount - headerCellCount
            }

            var result: [(String, Double)] = []
            for tr in trs[(headerRowIndex + 1)...] {
                guard let cells = (try? tr.select("td, th"))?.array(), cells.count > valueCol else { continue }
                let label = normalizeLabel((try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? "")
                guard label.contains("社債") || label.contains("借入金") || label.contains("リース")
                        || label.contains("コマーシャル・ペーパー") else { continue }
                guard let value = XBRLUtils.parseTextblockCellValue(try? cells[valueCol].text()) else { continue }
                result.append((label, value))
            }
            return result
        }

        struct DatedTable { let date: String; let table: Element; let values: [(label: String, value: Double)] }
        var candidates: [DatedTable] = []
        for table in tables {
            guard let trs = (try? table.select("tr"))?.array(), !trs.isEmpty else { continue }
            // ソニーグループ S100QZT6 実データ検証（2026-08-04）: 先頭行は「項目｜YYYY年M月D日」の
            // 2セル構成（日付は先頭セルではなく2番目のセル）。日立は先頭セル自体が日付。
            // 会社ごとにセル位置が変わるため、先頭行のセルを個別に見ず行全体のテキストから探す。
            // 日本精工 S100YFE3 実データ検証（2026-08-04）: 先頭行は「（単位：百万円）」のみの装飾行で、
            // 日付は2行目（「帳簿残高」等の列見出しと同じ行の先頭セル）にある。先頭数行をまとめて探す。
            let headerRowsText = trs.prefix(3).compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }.joined(separator: " ")
            let dateText: String
            if let match = jpDatePattern.firstMatch(in: headerRowsText, range: NSRange(headerRowsText.startIndex..., in: headerRowsText)),
               let dateRange = Range(match.range, in: headerRowsText) {
                dateText = String(headerRowsText[dateRange])
            } else if let fallback = precedingDate(before: table) {
                dateText = fallback
            } else {
                continue
            }
            // 少なくとも2行の借入金系ラベルを持つ表のみを対象とする（公正価値ヘッジ等の無関係な表を除外）。
            let values = bookValues(table)
            guard values.count >= 2 else { continue }
            candidates.append(DatedTable(date: dateText, table: table, values: values))
        }
        // いすゞ自動車 S100YFBQ 実データ検証（2026-08-04）: 同一日付の表が「金融負債の期日別残高」注記と
        // 「金融商品の公正価値」注記の2箇所に重複して現れる（帳簿価額は完全一致、公正価値注記側は短期
        // 借入金・リース負債を欠き行数が少ない）。日付ごとに最も行数が多い（＝最も網羅的な）表のみを残す。
        var bestByDate: [String: DatedTable] = [:]
        for candidate in candidates {
            if let existing = bestByDate[candidate.date], existing.values.count >= candidate.values.count {
                continue
            }
            bestByDate[candidate.date] = candidate
        }
        // 単一日付の表が同一行数で複数ある会社（信用格付別・通貨別の内訳等）は誤結合を避けるため対象外とする。
        guard bestByDate.count == 2 else { return nil }
        let sorted = bestByDate.values.sorted { $0.date < $1.date }  // "YYYY年M月D日" は西暦4桁固定のため文字列比較で時系列順

        let priorList = sorted[0].values
        let currentList = sorted[1].values
        guard !priorList.isEmpty || !currentList.isEmpty else { return nil }

        let priorMap = Dictionary(priorList, uniquingKeysWith: { first, _ in first })
        let currentMap = Dictionary(currentList, uniquingKeysWith: { first, _ in first })
        var orderedLabels: [String] = []
        var seen: Set<String> = []
        for label in (priorList + currentList).map(\.label) where !seen.contains(label) {
            seen.insert(label)
            orderedLabels.append(label)
        }

        let tableText = (try? sorted[1].table.text()) ?? (try? sorted[0].table.text()) ?? ""
        let scale: Double = tableText.contains("千円") ? 1_000
            : tableText.contains("億円") ? 100_000_000
            : Financial.millionYen

        // 三菱電機 S100YD3V 実データ検証（2026-08-04）: このパターンの「リース負債」行は流動/非流動へ
        // 分割されず、満期バケット（1年以内／1年超5年以内／5年超）を列として持つ単一の帳簿価額行。
        // `displayLabel` はマーカーの無いリース行を「非流動」とみなす既定を持つ（J-GAAP明細表・IFRS
        // 前/当比較表では流動/非流動が別行に分かれる前提のため）が、本パターンでは常に流動＋非流動の
        // 合算値であり「非流動」と表示すると値の範囲を偽ることになる。ここでは正規化せず生ラベルを使う。
        let components = orderedLabels.map { label in
            Row(
                label: label,
                current: currentMap[label].map { $0 * scale },
                prior: priorMap[label].map { $0 * scale },
                averageInterestRatePercent: nil
            )
        }
        let totalCurrent = currentMap.values.isEmpty ? nil : currentMap.values.reduce(0, +) * scale
        let totalPrior = priorMap.values.isEmpty ? nil : priorMap.values.reduce(0, +) * scale
        return (components, totalCurrent, totalPrior)
    }

    /// IFRS連結企業向け、社債・借入金の専用タグを持たない企業向けの最終フォールバック。
    /// 「金融商品に関する注記」汎用タグの中から、見出しアンカー方式の内訳表または満期構成の
    /// ペアテーブルを探す。会社独自拡張タグ（`ifrsShortTermBorrowingsAndLongTermDebtTextblockTag`）
    /// にペアテーブルが格納される会社も別途フォールバックする。
    private static func parseIFRSFinancialInstrumentsNote(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        if let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsFinancialInstrumentsTextblockTag),
           let soup = try? SwiftSoup.parse(html) {
            if let anchored = parseHeadingAnchoredComparisonTable(in: soup) { return anchored }
            if let paired = parseMaturityBucketPairTables(in: soup) { return paired }
        }
        if let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsShortTermBorrowingsAndLongTermDebtTextblockTag),
           let soup = try? SwiftSoup.parse(html) {
            return parseMaturityBucketPairTables(in: soup)
        }
        return nil
    }

    /// 表探索の入口。J-GAAP附属明細表を優先し、無ければIFRS注記（専用タグ→汎用タグの順）へ
    /// フォールバックする。
    private static func parseTable(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        parseJGaapScheduleTable(xbrlDir: xbrlDir)
            ?? parseIFRSNotesTable(xbrlDir: xbrlDir)
            ?? parseIFRSFinancialInstrumentsNote(xbrlDir: xbrlDir)
    }

    /// 借入金等明細表から有利子負債を積み上げ抽出する。
    /// IBD を XBRL タグで解決できない場合のフォールバック（会計基準は問わない）。
    static func extract(xbrlDir: URL, accountingStandard: String) -> IBDResult? {
        guard let parsed = parseTable(xbrlDir: xbrlDir) else { return nil }
        let components: [IBDComponentEntry] = parsed.rows.map { ($0.label, $0.current, $0.prior) }
        return IBDResult(
            total: parsed.totalCurrent,
            priorTotal: parsed.totalPrior,
            components: components,
            method: "borrowings_schedule",
            accountingStandard: accountingStandard
        )
    }

    /// 財務諸表注記取り込み `borrowings_schedule_cf_supplement` note_type 向け。`extract` と異なり
    /// 平均利率も保持したまま行を返す（IBD 合算には使わない生の明細表データ）。
    static func extractRows(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        parseTable(xbrlDir: xbrlDir)
    }
}
