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
        // HOYA S100Y90T 実データ検証（2026-08-05）: 「短期リース負債」「長期リース負債」という
        // 対で開示する会社がある。"短期" が判定マーカーに無かったため両方とも「非流動」に
        // 誤分類され区別が失われていた（値も欠落したように見えるラベル重複を引き起こす）。
        let currentMarkers = ["1年以内", "1年内", "１年以内", "１年内", "流動", "短期"]
        let isCurrent = currentMarkers.contains { normalizedLabel.contains($0) }
        return isCurrent ? "リース負債（流動）" : "リース負債（非流動）"
    }

    /// フィルタ通過前の1行分（インデント深さつき）。`label` は displayLabel 適用前の生ラベル。
    /// `isVerticalStackItem` は同一セル内の縦積み（カテゴリ+内訳）から分解された行かどうか
    /// （直前の無関係な行を巻き込んで誤って除外しないための区別。詳細は呼び出し元コメント参照）。
    private struct RawRow {
        let label: String
        let indent: Double
        let current: Double?
        let prior: Double?
        let rate: Double?
        let isVerticalStackItem: Bool
    }

    /// ラベルセル内の `<p>` 分割が「カテゴリ名+内訳の縦積み」か「単に列幅で折り返しただけの
    /// 1つのラベル」かを、開き括弧の対応関係で判定する。東京電力 S100YIHR・ダイキン S100YFQL
    /// 実データ検証（2026-08-05）: 縦積みは各 `<p>` が独立した完結語（「その他有利子負債」
    /// 「コマーシャル・ペーパー(１年以内に償還)」等、括弧が各々で閉じている）。三菱地所 S100YBLA
    /// 実データ検証: 折り返しは括弧の途中で行が割れる（「ノンリコース長期借入金（1年以内に返済予定の」
    /// ＋「ものを除く）」で前半の開き括弧が後半まで閉じない）。前半セグメントで開き括弧が閉じ括弧より
    /// 多ければ折り返しとみなす。
    private static func isLineWrapContinuation(firstSegment: String) -> Bool {
        let opens = firstSegment.filter { $0 == "（" || $0 == "(" }.count
        let closes = firstSegment.filter { $0 == "）" || $0 == ")" }.count
        return opens > closes
    }

    /// ラベルの前後の全角/半角スペース・nbsp を除去する（"合計"／"計" 判定・displayLabel 適用の前処理）。
    private static func normalizeLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
    }

    /// 流動／非流動の切り口による参考内訳・区分内合計か。クボタ型（bare「計」の直後に同じ総額を
    /// 「流動負債」「非流動負債」で並記）や HOYA 型（真の「有利子負債合計」の後に
    /// 「流動合計」「非流動合計」が続く）で、これらを表全体の真の合計と誤認しないために使う。
    /// 監査レビュー残リスク（2026-08-08）: bare「計」判定で「〜合計」を無条件に真の合計証拠と
    /// すると、restatement が「流動負債合計」表記の会社で true になり bare「計」を読み飛ばして
    /// 部分合計を真の合計として採用してしまう。
    private static func isRestatementOrSectionTotalLabel(_ label: String) -> Bool {
        let exact: Set<String> = [
            "流動負債", "非流動負債",
            "流動負債合計", "非流動負債合計",
            "流動合計", "非流動合計",
        ]
        return exact.contains(label)
    }

    /// 表全体の真の合計行か（restatement／区分内合計を除外した `〜合計`）。
    private static func isGrandTotalLabel(_ label: String) -> Bool {
        if label == "合計" { return true }
        return label.hasSuffix("合計") && !isRestatementOrSectionTotalLabel(label)
    }

    /// ラベルセルの先頭 `<p>` からインデント深さを読む。実データ検証（2026-08-02〜2026-08-08）:
    /// 階層表現は会社により複数ある。① CSS `margin-left`（例: あおぞら銀行、pxをそのまま深さに使う）
    /// ② CSS `padding-left`（例: 三菱UFJ・三井住友、`padding-left:13.6pt` のように小数pt単位。
    /// 「借用金」（カテゴリ小計、padding-leftなし）に対し「借入金」「再割引手形」（内訳）が
    /// padding-left付きで区別される。margin-leftのみを見ていた旧実装ではこのパターンを検出できず、
    /// 小計と内訳が二重計上されていた）③ 全角/半角スペース・nbsp をラベル文字列先頭に付けるだけ
    /// （例: コンコルディア「　　借入金」、しずおかFG「　借入金」。①②のインデントが検出できない
    /// 場合はこちらにフォールバックする）。`<p>` が無い（インデント情報自体が無い）行は 0
    /// （トップレベル）として扱う。単位混在（px/pt）はテーブル間で比較しないため問題にならない。
    private static func indentLevel(of p: Element?) -> Double {
        guard let p else { return 0 }
        if let style = try? p.attr("style"),
           let regex = try? NSRegularExpression(
               pattern: "(?:margin-left|padding-left):\\s*([\\d.]+)(?:px|pt)"),
           let match = regex.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
           let numRange = Range(match.range(at: 1), in: style),
           let value = Double(style[numRange]), value > 0 {
            return value
        }
        let raw = (try? p.text(trimAndNormaliseWhitespace: false)) ?? ""
        return Double(raw.prefix { $0 == " " || $0 == "\u{3000}" || $0 == "\u{00A0}" }.count)
    }

    /// `rawRows[parentIndex]` の部分木内に、除外根拠となる値あり子孫があるか。
    /// 値なしの深い行は「空の実体行（親の子）」か「介入する別見出し（自身に子孫あり）」かを
    /// さらに先読みして区別する。縦積み分解行に当たったら部分木探索を打ち切る。
    private static func hasValuedDescendantInSubtree(_ rawRows: [RawRow], parentIndex: Int) -> Bool {
        let parentIndent = rawRows[parentIndex].indent
        var j = parentIndex + 1
        while j < rawRows.count {
            let row = rawRows[j]
            if row.isVerticalStackItem { return false }
            if row.indent <= parentIndent { return false }
            if row.current != nil || row.prior != nil { return true }
            // 値なしの深い行: 自身に値あり子孫がいれば介入見出し → 親の除外根拠にしない。
            if hasValuedDescendantInSubtree(rawRows, parentIndex: j) { return false }
            // 葉の空行（親の子）→ 同じ部分木内の次の兄弟を続ける。
            j += 1
        }
        return false
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
        // 東邦レマック S100XRD8 実データ検証（2026-08-08）: 連結財務諸表を作成しない小規模企業は
        // 連結版タグを持たず、単体版タグのみに明細表が入る。列構成・「合計」行判定は共通のため、
        // 連結版が見つからない場合のみ単体版へフォールバックする。
        guard let html = XBRLUtils.extractTextblockHtml(
                in: xbrlDir, textblockTag: Xbrl.borrowingsScheduleTextblockTag)
                ?? XBRLUtils.extractTextblockHtml(
                    in: xbrlDir, textblockTag: Xbrl.borrowingsScheduleNonConsolidatedTextblockTag),
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
            let firstLabelSegment = labelPs.first.flatMap { try? $0.text(trimAndNormaliseWhitespace: true) } ?? ""

            // 東京電力 S100YIHR・ダイキン S100YFQL 実データ検証（2026-08-05）: labelPs.count > 1 は
            // 「カテゴリ名+内訳の縦積み」だけでなく、三菱地所 S100YBLA のような「単に列幅で折り返した
            // 1つのラベル」も含む（開き括弧が閉じないまま次の<p>へ続く）。折り返しの場合は縦積みとして
            // 分解せず、cells[0].text() で全<p>を結合した1つのラベルとして通常行と同じ経路で処理する
            // （でないと後半`<p>`の「値なし」判定で行自体が消え、前半`<p>`だけの途中で切れたラベルが残る）。
            if labelPs.count > 1, !isLineWrapContinuation(firstSegment: firstLabelSegment) {
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
                    // 縦積みされた内訳行は常に末端（それ以上の階層を持たない）として扱う。直前の
                    // 無関係な行を「自分の子」と誤認させないよう `isVerticalStackItem` で区別する。
                    rawRows.append(RawRow(
                        label: label, indent: .infinity, current: current, prior: prior, rate: rate,
                        isVerticalStackItem: true))
                }
                continue
            }

            let label = normalizeLabel((try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? "")
            guard !label.isEmpty else { continue }

            let prior = XBRLUtils.parseTextblockCellValue(try? cells[1].text())
            let current = XBRLUtils.parseTextblockCellValue(try? cells[2].text())
            let rate = cells.count >= 4 ? XBRLUtils.parseTextblockCellValue(try? cells[3].text()) : nil

            if label == "合計" || label == "計" {
                totalCurrent = current.map { $0 * scale }
                totalPrior = prior.map { $0 * scale }
                break rowLoop  // 合計以降は返済予定額の別表
            }
            // 三菱地所 S100YBLA 実データ検証（2026-08-05）: `parseComparisonTable` と同様、区分内
            // 小計「小計」は除外する（真の合計は別行の「合計」）。除外しないと二重計上になる。
            if label == "小計" { continue }
            // ニチレイ S100VYA0 実データ検証（2026-08-08）: 「その他有利子負債」のような値なしの
            // 区分見出し行を、以前はここで即座に `continue`（RawRow化せず消える）していた。その結果
            // 見出しの子（コマーシャル・ペーパー等）のインデントが、rawRows上で直前の無関係な実体行
            // （リース債務（非流動）等）に付け違えられ、その行が「子を持つカテゴリ小計」と誤認されて
            // 消えていた（値のある行が丸ごと欠落するバグ）。値なし行も indent 付きの RawRow として
            // 残し、内訳を持つカテゴリ小計として除外されなかった場合のみ、後段（component化時）で
            // 値なしとして最終的に落とす。
            rawRows.append(RawRow(
                label: label, indent: indentLevel(of: labelPs.first), current: current, prior: prior, rate: rate,
                isVerticalStackItem: false))
        }

        // カテゴリ小計（内訳がぶら下がる行）を除外し、二重計上を防ぐ。
        //
        // 判定は「直後1行」ではなく、同じ部分木内の値あり子孫を先読みする。
        // - あおぞら銀行/MUFG: 「借用金」(値あり) → 「再割引手形」(値なし・深い) → 「借入金」(値あり・深い)
        //   値なしの子を挟んでも、先の値あり子孫が見えれば親を除外する。
        // - ニチレイ: 「リース」(値あり) → 「その他有利子負債」(値なし・同インデント) → 子
        //   同インデントの値なし見出しは部分木を閉じるので、リースは除外されない。
        // - 監査レビュー残リスク: 値なし見出しが直前行より深い場合、その見出し自身に値あり子孫が
        //   いれば「介入する別見出し」とみなし、直前行は除外しない。
        // 縦積み分解由来（`isVerticalStackItem`）は直前行と無関係なため除外根拠にしない
        // （東京電力 S100YIHR・ダイキン S100YFQL 実データ検証2026-08-05）。
        var components: [Row] = []
        for i in rawRows.indices {
            if hasValuedDescendantInSubtree(rawRows, parentIndex: i) { continue }
            let r = rawRows[i]
            // 区分ヘッダ・「該当事項はありません」等の非数値行（内訳を持つカテゴリ小計として上で
            // 除外されなかったもの）は出力しない。
            guard r.current != nil || r.prior != nil else { continue }
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
            ?? XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsBondsBorrowingsAndOtherFinancialLiabilitiesTextblockTag)
            ?? XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsBondsIssuedBorrowingsAndInvestmentContractLiabilitiesTextblockTag)
            ?? XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsOtherFinancialLiabilitiesTextblockTag)
            ?? XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsDisclosuresAboutFinancialAndOtherTradeLiabilitiesTextblockTag)
            ?? XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsOtherFinancialAssetsAndOtherFinancialLiabilitiesTextblockTag)
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
        // ファーストリテイリング S100X6X6 実データ検証（2026-08-04）: 「その他の金融資産及びその他の
        // 金融負債」のように資産・負債セクションが同一タグ内に併存する会社がある。資産側の表も
        // 「前」「当」列を持つため銘柄除外だけでは資産表を誤選択する。社債・借入金・リース・
        // 有利子負債のいずれかを含む表のみを対象にする。
        let candidateTables = tables.filter {
            let t = (try? $0.text()) ?? ""
            guard !t.contains("銘柄") else { return false }
            guard t.contains("社債") || t.contains("借入金") || t.contains("リース") || t.contains("有利子負債") else { return false }
            return (t.contains("前") && t.contains("当")) || jpDateMatchCount(t) >= 2
        }
        // 三井物産 S100YAVT 実データ検証（2026-08-04）: 「短期銀行借入金等」と「長期債務」が別々の表
        // に分かれる（短期表のみを拾うと不完全な合計になる）。該当する表が複数あれば全て解析し、
        // 行を連結・合計を合算する。三菱重工業 S100YHZG 実データ検証（2026-08-04）: 相殺（ネッティング）
        // 開示表も「社債、借入金」を区分見出しに含み前/当列を持つため候補に混入するが、真の「合計」行を
        // 持たず`parseComparisonTable`のフォールバック自己合算（無関係な行の総和）で見かけ上成功して
        // しまう。合算対象は明示的な「合計」行を持つ表のみに限定する（フォールバック合算の表は除外）。
        func hasExplicitTotalRow(_ table: Element) -> Bool {
            guard let trs = (try? table.select("tr"))?.array() else { return false }
            for tr in trs {
                guard let cells = (try? tr.select("td, th"))?.array(), let first = cells.first else { continue }
                let label = normalizeLabel((try? first.text(trimAndNormaliseWhitespace: true)) ?? "")
                // restatement の「流動負債合計」等は明示的な表合計とみなさない（クボタ型と区別）。
                if isGrandTotalLabel(label) { return true }
            }
            return false
        }
        let combinableTables = candidateTables.filter(hasExplicitTotalRow)
        let parsedCombinable = combinableTables.compactMap { parseComparisonTable($0) }
        // HOYA S100Y90T 実データ検証（2026-08-05）: 本体の前/当比較表とは別に、同じ科目
        // （短期借入金・長期借入金・リース負債等）をロールフォワード形式（期首残高｜CF変動｜
        // 期末残高）で重複開示する表が2つ並び、いずれも「合計」行を持つため合算対象に混入する
        // （本体表と合わせて三重計上になる）。三井物産のような正当な合算（短期表＋長期表）は
        // ラベルが重複しない前提のため、行ラベルに重複が無い場合のみ合算する。重複があれば
        // 合算せず、`hasExplicitTotalRow` を満たす最初の1件のみを使う（ロールフォワード表は
        // 後述の他経路で無視される）。
        let allLabels = parsedCombinable.flatMap { $0.rows.map(\.label) }
        let hasDuplicateLabels = Set(allLabels).count != allLabels.count
        // ＳＢＩホールディングス S100YK3R 実データ検証（2026-08-06）: 同一テキストブロック内に
        // 「社債及び借入金の内訳」表（合計＝連結BSの社債及び借入金と一致する正解）とは別に、
        // 「売却目的保有資産に直接関連する負債の内訳」表が並ぶ。後者は社債及び借入金の集約1行に
        // 加え顧客預金・その他の金融負債・その他の負債という無関係な科目が同居し、こちらも「合計」
        // 行を持つため合算対象に混入する（ラベルは前者と重複しないため三井物産向けの重複排除では
        // 防げない）。三菱重工業・住友金属鉱山・東京海上のように「1つの正当な表」自体にデリバティブ
        // 負債等の非借入項目が意図的に混在するケースがあるため、この判定は「合算するかどうか」の
        // 判断にのみ使い、単一表の採否には使わない（`isDebtOnlyTable`を`parsedCombinable`全体の
        // フィルタにすると、単一の正当な混在表まで弾かれて`hasExplicitTotalRow`を経由しない
        // `candidateTables.first`の無防備な再パースに落ち、三菱重工業向けに追加したネッティング表
        // 除外ガードを迂回してしまう）。
        func isDebtOnlyTable(_ parsed: (rows: [Row], totalCurrent: Double?, totalPrior: Double?)) -> Bool {
            let debtKeywords = ["社債", "借入", "借用金", "リース", "コマーシャル・ペーパー", "有利子負債"]
            return parsed.rows.allSatisfy { row in debtKeywords.contains { row.label.contains($0) } }
        }
        if parsedCombinable.count > 1, !hasDuplicateLabels, parsedCombinable.allSatisfy(isDebtOnlyTable) {
            let combinedRows = parsedCombinable.flatMap(\.rows)
            let totalCurrent = parsedCombinable.compactMap(\.totalCurrent).reduce(0, +)
            let totalPrior = parsedCombinable.compactMap(\.totalPrior).reduce(0, +)
            return (combinedRows, totalCurrent, totalPrior)
        }
        // ＳＢＩホールディングス: 合算しない場合、複数の非合算対象候補（表0＝正しい内訳、表3＝
        // 無関係カテゴリ混在）の中から、存在すれば純粋な社債・借入金系ラベルのみの表を優先する
        // （DOM順に依存せず正解表を選ぶ。三菱重工業等、唯一の候補自体が非借入項目を含む場合は
        // 該当なしとなり次のプレーンな`.first`にフォールスルーする＝挙動不変）。
        if let pureDebtFirst = parsedCombinable.first(where: isDebtOnlyTable) { return pureDebtFirst }
        if let result = parsedCombinable.first { return result }
        if let table = candidateTables.first, let result = parseComparisonTable(table) { return result }

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
        guard var priorIdx, var currentIdx, headerRowIndex >= 0, headerRowIndex + 1 < trs.count else { return nil }

        // 三井物産 S100YAVT 実データ検証（2026-08-04）: 「前期／当期」見出し行の直下に「金額｜利率｜
        // 金額｜利率」という実列見出し行が続く2段ヘッダーがある。上段だけでは前期・当期の列位置が
        // 実データ行（金額・利率がそれぞれ別列）とズレる（当期の値の代わりに前期の利率を読んでしまう）。
        // 直下の行に「金額」が2回以上現れる場合はそちらを実ヘッダーとして列位置を取り直す。
        if let subHeaderCells = (try? trs[headerRowIndex + 1].select("td, th"))?.array() {
            let amountCols = subHeaderCells.enumerated().compactMap { j, cell -> Int? in
                let text = (try? cell.text(trimAndNormaliseWhitespace: true)) ?? ""
                return text.contains("金額") ? j : nil
            }
            let rateCols = subHeaderCells.enumerated().compactMap { j, cell -> Int? in
                let text = (try? cell.text(trimAndNormaliseWhitespace: true)) ?? ""
                return text.contains("利率") ? j : nil
            }
            if amountCols.count >= 2 {
                // このサブヘッダー行自体はラベル列を持たない（「金額｜利率｜金額｜利率」の4セルのみ）が、
                // 直後の実データ行は先頭にラベル列を持つ（5セル）。ソニーグループ同様、セル数の差分だけ
                // 右にずらす。
                var offset = 0
                if headerRowIndex + 2 < trs.count,
                   let dataCells = (try? trs[headerRowIndex + 2].select("td, th"))?.array() {
                    offset = max(0, dataCells.count - subHeaderCells.count)
                }
                priorIdx = amountCols[0] + offset
                currentIdx = amountCols[1] + offset
                rateIdx = (rateCols.count >= 2 ? rateCols[1] : rateCols.first).map { $0 + offset }
                headerRowIndex += 1
            }
        }
        guard headerRowIndex + 1 < trs.count else { return nil }

        // クボタ S100XR0M 実データ検証（2026-08-08、smoke対象企業のΣ内訳vs合計チェックで発見）:
        // 「短期借入金／社債及び長期借入金」の内訳表全体の真の合計が「合計」ではなく無印の「計」
        // 1本のみで、その直後に同じ総額を「流動負債／非流動負債」という別の切り口で並記した参考
        // 内訳が続く（末尾に「合計」行は無い）。三井物産型（区分内小計が無印「計」、表全体の真の
        // 合計は別行の「合計」）と表記上は同形のため、その場では区別できない。表全体を先読みし、
        // 真の合計行（「合計」または restatement を除く「〜合計」）があるかどうかで判定する:
        // あれば三井物産型（無印「計」は区分内小計として読み飛ばす）、無ければクボタ型
        // （無印「計」自体が表全体の真の合計）とみなす。
        // 監査レビュー残リスク対応（2026-08-08）: 「流動負債合計」「非流動負債合計」等の
        // restatement ラベルは真の合計証拠から除外する（これらがあると旧判定は true になり、
        // bare「計」を読み飛ばして部分合計を採用してしまう）。
        // 日東電工 S100VYH3 実データ検証（2026-08-03）: ラベル列の前に幅の狭いインデント専用の空セルが
        // 挟まる会社がある。本読み込みループ（下）と同じ cells[0]→cells[1] フォールバックで抽出しない
        // と、その種の会社では「合計」行がここで見えず `hasDistinctGrandTotalRow` が誤って false になる。
        let hasDistinctGrandTotalRow = trs[(headerRowIndex + 1)...].contains { tr in
            guard let cells = (try? tr.select("td, th"))?.array(),
                  cells.count > max(priorIdx, currentIdx) else { return false }
            var label = normalizeLabel((try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? "")
            if label.isEmpty, cells.count > 1 {
                label = normalizeLabel((try? cells[1].text(trimAndNormaliseWhitespace: true)) ?? "")
            }
            return isGrandTotalLabel(label)
        }

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

            // 三井物産 S100YAVT 実データ検証（2026-08-04）: 「担保付長期債務」「無担保長期債務」の
            // 各区分末尾に無印の「計」（区分内小計）が付き、表全体の真の合計は末尾の「合計」のみ。
            if label == "小計" { continue }
            // 流動／非流動の参考内訳はコンポーネントにも合計にも使わない（クボタ型の二重計上防止）。
            if isRestatementOrSectionTotalLabel(label) { continue }
            if label == "計" {
                if hasDistinctGrandTotalRow { continue }  // 三井物産型: 区分内小計として読み飛ばす
                totalCurrent = current.map { $0 * scale }  // クボタ型: 「計」自体が表全体の真の合計
                totalPrior = prior.map { $0 * scale }
                break rowLoop
            }
            if isGrandTotalLabel(label) {
                totalCurrent = current.map { $0 * scale }
                totalPrior = prior.map { $0 * scale }
                break rowLoop   // 真の合計に到達。以降の参考内訳は無視する
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
    private static func parseMaturityBucketPairTables(
        in document: Document, minMatchingRows: Int = 2
    ) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
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
            // 少なくとも`minMatchingRows`行の借入金系ラベルを持つ表のみを対象とする（公正価値ヘッジ等の
            // 無関係な表を除外）。既定2行だが、リース専用注記等トピックが単一の場合は1行に緩める。
            let values = bookValues(table)
            guard values.count >= minMatchingRows else { continue }
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

    /// トヨタ自動車 S100Y8NY 実データ検証（2026-08-04）: `ifrsInterestBearingLiabilitiesTextblockTag`は
    /// 存在するが、前/当の比較列を持つ通常表ではなく、会計年度ごとに「期首残高｜キャッシュ・フロー
    /// 内訳｜非資金変動内訳｜期末残高」のロールフォワード表が2つ（前年度分・当年度分）並ぶ。列見出しは
    /// 中間の内訳列を除き日付のみ（"帳簿価額"等のラベルは無い）。各行の最終セルが期末残高のため、
    /// ラベル（先頭セル）と最終セルの組だけを読む（中間のCF内訳列数が会社によらず変わっても頑健）。
    /// 短期借入債務・１年以内返済予定長期借入債務・長期借入債務・（各）リース負債を拾い、区分内小計
    /// 「流動合計」「非流動合計」は除外、真の合計「有利子負債合計」に達したら打ち切る。
    private static func parseRollforwardEndingBalancePairTables(
        in document: Document
    ) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let tables = (try? document.select("table"))?.array(),
              let jpDatePattern = try? NSRegularExpression(pattern: "\\d{4}年\\d{1,2}月\\d{1,2}日") else { return nil }

        struct EndingBalanceTable { let closingDate: String; let rows: [(label: String, value: Double)]; let total: Double }
        var candidates: [EndingBalanceTable] = []
        for table in tables {
            guard let trs = (try? table.select("tr"))?.array(), trs.count > 3 else { continue }
            // トヨタ自動車 S100Y8NY 実データ検証（2026-08-04）: 年（例「2024年」）と月日（例「４月１日」）が
            // セル内で別々の<p>に分かれており、text()が間に空白を挟むため空白を除去してから日付照合する。
            let headerText = trs.prefix(2).compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
                .joined(separator: " ").replacingOccurrences(of: " ", with: "")
            let dateMatches = jpDatePattern.matches(in: headerText, range: NSRange(headerText.startIndex..., in: headerText))
                .compactMap { Range($0.range, in: headerText).map { String(headerText[$0]) } }
            guard dateMatches.count >= 2, let closingDate = dateMatches.last else { continue }

            var rows: [(String, Double)] = []
            var total: Double?
            rowLoop: for tr in trs {
                guard let cells = (try? tr.select("td, th"))?.array(), let first = cells.first, cells.count >= 2 else { continue }
                let label = normalizeLabel((try? first.text(trimAndNormaliseWhitespace: true)) ?? "")
                guard !label.isEmpty, let value = XBRLUtils.parseTextblockCellValue(try? cells[cells.count - 1].text()) else { continue }
                if label == "有利子負債合計" {
                    total = value
                    break rowLoop
                }
                if label.hasSuffix("合計") { continue }   // 流動合計・非流動合計（区分内小計）は除外
                guard label.contains("社債") || label.contains("借入") || label.contains("リース") else { continue }
                rows.append((label, value))
            }
            guard rows.count >= 2, let total else { continue }
            candidates.append(EndingBalanceTable(closingDate: closingDate, rows: rows, total: total))
        }
        guard candidates.count == 2 else { return nil }
        let sorted = candidates.sorted { $0.closingDate < $1.closingDate }

        let priorMap = Dictionary(sorted[0].rows, uniquingKeysWith: { first, _ in first })
        let currentMap = Dictionary(sorted[1].rows, uniquingKeysWith: { first, _ in first })
        var orderedLabels: [String] = []
        var seen: Set<String> = []
        for label in (sorted[0].rows + sorted[1].rows).map(\.label) where !seen.contains(label) {
            seen.insert(label)
            orderedLabels.append(label)
        }
        let tableText = (try? document.text()) ?? ""
        let scale: Double = tableText.contains("千円") ? 1_000
            : tableText.contains("億円") ? 100_000_000
            : Financial.millionYen
        // 他経路（`parseComparisonTable`等）と表示ラベルを揃えるため、リース行は`displayLabel`で
        // 「リース負債（流動/非流動）」へ正規化する（トヨタの生ラベルは「１年以内返済予定長期
        // リース負債」「長期リース負債」で、既存のマーカー判定がそのまま適用できる）。
        let components = orderedLabels.map { label in
            Row(
                label: displayLabel(for: label),
                current: currentMap[label].map { $0 * scale },
                prior: priorMap[label].map { $0 * scale },
                averageInterestRatePercent: nil
            )
        }
        return (components, sorted[1].total * scale, sorted[0].total * scale)
    }

    /// ディスコ S100YC6I・中外製薬 S100XTBJ 実データ検証（2026-08-04）: 借入金等明細表／社債・借入金
    /// 注記が無くても、リース負債のみ計上している会社がある（無借金だがオペレーティングリース資産を
    /// 保有）。「リース取引に関する注記」専用タグを最終フォールバックとして試す。この注記はリース
    /// 以外の話題を含まないため、他の経路と異なり社債・借入金キーワード必須の候補選定は適用しない。
    private static func parseLeaseOnlyNote(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        if let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.jGaapLeasesNoteTextblockTag),
           let soup = try? SwiftSoup.parse(html),
           let tables = (try? soup.select("table"))?.array() {
            // 監査指摘（2026-08-05）: 「前/当を含む最初の表」を無絞りで採用しており、リース以外の
            // 話題を持つ表を誤って拾う理論上の余地はある。ただしディスコ S100YC6I 実データ検証では
            // 表本体に「リース」という語自体が無い（区分ラベルが「１年内」「１年超」のみ）ため、
            // 表内キーワード必須にすると正当なケースまで壊れる。本タグはリース以外の話題を含まない
            // 単一トピック注記のため、`hasExplicitTotalRow` と同様「合計」行を持つ最初の表という
            // 制約のみに留める（`parseComparisonTable` 自体が合計行の無い表を弾く）。
            let table = tables.first {
                let t = (try? $0.text()) ?? ""
                return t.contains("前") && t.contains("当")
            }
            if let table, let result = parseComparisonTable(table) { return result }
        }
        // 中外製薬 S100XTBJ 実データ検証（2026-08-04）: このタグはリース以外の話題を含まないため
        // 「リース負債」1行のみでも有効な満期構成ペアテーブルとみなす（通常経路の2行以上要件
        // ＝無関係な表の誤選択防止は、単一トピックの本タグには不要）。
        if let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsLeasesTextblockTag),
           let soup = try? SwiftSoup.parse(html),
           let paired = parseMaturityBucketPairTables(in: soup, minMatchingRows: 1) {
            return paired
        }
        return nil
    }

    /// 三井物産 S100YAVT 実データ検証（2026-08-04）: 連結BSの短期負債・1年内返済予定の長期負債・
    /// 長期負債（非流動、リース負債等を含め合算済み）が個別の数値タグとして存在する会社では、
    /// 注記のHTML明細表（区分見出し行と金額行が分離しラベル品質が悪い等）をパースするより
    /// こちらを優先する。3タグとも揃っている場合のみ採用する（一部だけでは合計が不完全になるため）。
    /// ローカル名で引く（`XBRLUtils.collectAllNumericFacts`は名前空間プレフィックスを問わない）ため
    /// 標準タグ・自社拡張タグのどちらでも解決する。
    private static func parseDirectDebtFacts(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        let tagLabels: [(tag: String, label: String)] = [
            ("ShortTermDebtCLIFRS", "短期負債"),
            ("CurrentPortionOfLongTermDebtCLIFRS", "1年内返済予定の長期負債"),
            ("LongTermDebtNCLIFRS", "長期負債"),
        ]
        var rows: [Row] = []
        for (tag, label) in tagLabels {
            guard let currentFact = facts[tag]?["CurrentYearInstant"] else { continue }
            let priorValue = facts[tag]?["Prior1YearInstant"]?.value
            rows.append(Row(label: label, current: currentFact.value, prior: priorValue, averageInterestRatePercent: nil))
        }
        guard rows.count == tagLabels.count else { return nil }
        let totalCurrent = rows.compactMap(\.current).reduce(0, +)
        let priorValues = rows.compactMap(\.prior)
        let totalPrior = priorValues.count == rows.count ? priorValues.reduce(0, +) : nil
        return (rows, totalCurrent, totalPrior)
    }

    /// 表探索の入口。直接タグ（揃っている場合）→ J-GAAP附属明細表 → IFRS注記（専用タグ→汎用タグの順）
    /// の順にフォールバックする。US-GAAP 巨大注記は `extractRows` のみが読む（IBD は HTML 仮想タグ
    /// ＋オペレーティング・リース加算を維持するため `extract` には載せない）。
    private static func parseTable(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        parseDirectDebtFacts(xbrlDir: xbrlDir)
            ?? parseJGaapScheduleTable(xbrlDir: xbrlDir)
            ?? parseIFRSNotesTable(xbrlDir: xbrlDir)
            ?? parseIFRSFinancialInstrumentsNote(xbrlDir: xbrlDir)
            ?? parseLeaseOnlyNote(xbrlDir: xbrlDir)
            ?? parseRollforwardNote(xbrlDir: xbrlDir)
    }

    /// US-GAAP 連結の借入金等明細。附属明細表タグは注記へのクロスリファレンスのみ（表なし）で、
    /// 本体は `NotesToConsolidatedFinancialStatementsUSGAAPTextBlock` 内の注番号見出し配下にある。
    /// 実データ検証（2026-08-12）:
    /// - 富士フイルム S100W3XJ 注記9「短期の社債及び借入金・長期の社債及び借入金」:
    ///   短期は前/当比較表、長期は区分見出し＋銘柄別「返済期限」行＋控除/差引計。
    ///   １年以内返済は長期グロスと二重になるため落とす。オペレーティング・リースは別注記。
    /// - キヤノン S100XTLJ 注9「短期借入金及び長期債務」: 短期は散文の百万円ペア、
    ///   長期は colspan 付き比較表（銀行借入／その他の債務）。
    /// IBD（`extract`）には使わない。notes の内訳表であり、IBD 合計（リース込み HTML 仮想タグ）とは母数が違う。
    private static func parseUSGAAPNotesTable(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let html = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: Xbrl.notesToConsolidatedFinancialStatementsUSGAAPTextBlock)
        else { return nil }
        return parseUSGAAPNotesHtml(html)
    }

    /// テスト用に HTML 文字列からも同じ経路を踏めるようにする（CI は EDINET キャッシュ無しでも
    /// 表形状・散文ペア・控除行の扱いを固定できる）。
    static func parseUSGAAPNotesHtml(_ html: String) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let soup = try? SwiftSoup.parse(html) else { return nil }
        return parseUSGAAPNotesDocument(soup)
    }

    private static let usgaapNoteHeadingPattern = try! NSRegularExpression(
        pattern: "^(?:注記?|注)?[0-9０-９]{1,2}[\\s　]")
    private static let usgaapYearRowPattern = try! NSRegularExpression(pattern: "^[0-9]{4}年度")
    private static let usgaapDatePattern = try! NSRegularExpression(pattern: "\\d{4}年\\d{1,2}月\\d{1,2}日")
    private static let usgaapFiscalTermPattern = try! NSRegularExpression(pattern: "第\\d+期")
    private static let usgaapRateInLabelPattern = try! NSRegularExpression(
        pattern: "(?:年利率|銀行利率)\\s*([0-9.]+)[％%]")
    private static let usgaapMillionYenPairPattern = try! NSRegularExpression(
        pattern: "([^。]+?)(?:は、それぞれ|は)([0-9,]+)百万円、([0-9,]+)百万円")
    private static let usgaapFootnoteMarkerPattern = try! NSRegularExpression(pattern: "[*＊][0-9]+")

    private static func isUSGAAPNoteHeading(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.unicodeScalars.count <= 80 else { return false }
        let range = NSRange(t.startIndex..., in: t)
        return usgaapNoteHeadingPattern.firstMatch(in: t, range: range) != nil
    }

    private static func isUSGAAPDebtNoteHeading(_ text: String) -> Bool {
        guard isUSGAAPNoteHeading(text) else { return false }
        return text.contains("借入金") || text.contains("長期債務") || text.contains("有利子負債")
    }

    private static func isInsideTable(_ element: Element) -> Bool {
        var parent = element.parent()
        while let cur = parent {
            if cur.tagName() == "table" { return true }
            parent = cur.parent()
        }
        return false
    }

    private static func parseUSGAAPNotesDocument(
        _ document: Document
    ) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let all = (try? document.getAllElements())?.array() else { return nil }
        var inDebtNote = false
        var tables: [Element] = []
        var proseChunks: [String] = []
        for el in all {
            let text = (try? el.text(trimAndNormaliseWhitespace: true)) ?? ""
            if isUSGAAPDebtNoteHeading(text) {
                inDebtNote = true
                continue
            }
            if inDebtNote, isUSGAAPNoteHeading(text), !isUSGAAPDebtNoteHeading(text) {
                break
            }
            guard inDebtNote else { continue }
            if el.tagName() == "table" {
                tables.append(el)
            } else if el.tagName() == "p", !isInsideTable(el), !text.isEmpty {
                proseChunks.append(text)
            }
        }

        var tableRows: [Row] = []
        for table in tables {
            guard let parsed = parseUSGAAPDebtComparisonTable(table) else { continue }
            tableRows.append(contentsOf: parsed)
        }
        let proseRows = parseUSGAAPShortTermFromProse(proseChunks.joined(separator: "。"))
        let hasShortTermTable = tableRows.contains {
            $0.label.contains("短期借入金") || $0.label.contains("コマーシャル")
        }
        let shortTerm = hasShortTermTable ? [] : proseRows
        var combined = shortTerm + tableRows
        let hasLongTermInstrument = combined.contains { isUSGAAPLongTermInstrumentLabel($0.label) }
        if hasLongTermInstrument {
            combined.removeAll { isUSGAAPCurrentPortionLabel($0.label) }
        }
        combined = mergeConsecutiveSameLabels(combined)

        guard !combined.isEmpty else { return nil }
        let totalCurrent = combined.compactMap(\.current).reduce(0, +)
        let priorValues = combined.compactMap(\.prior)
        let totalPrior = priorValues.isEmpty ? nil : priorValues.reduce(0, +)
        return (combined, totalCurrent, totalPrior)
    }

    private static func isUSGAAPCurrentPortionLabel(_ label: String) -> Bool {
        label.contains("１年以内") || label.contains("1年以内")
            || label.contains("１年内") || label.contains("1年内")
    }

    private static func isUSGAAPLongTermInstrumentLabel(_ label: String) -> Bool {
        if label.contains("短期") { return false }
        return label.contains("無担保借入") || label.contains("銀行借入")
            || label.contains("無担保社債") || label.contains("その他の債務")
            || label.contains("社債")
    }

    private static func isUSGAAPColumnHeaderLabel(_ label: String) -> Bool {
        if label.contains("百万円") || label.contains("千円") || label.contains("億円") { return true }
        if label.contains("前連結") || label.contains("当連結") { return true }
        let range = NSRange(label.startIndex..., in: label)
        if usgaapFiscalTermPattern.firstMatch(in: label, range: range) != nil { return true }
        if usgaapDatePattern.firstMatch(in: label, range: range) != nil { return true }
        return false
    }

    private static func isUSGAAPSkipRowLabel(_ label: String) -> Bool {
        if label.isEmpty { return true }
        if label == "小計" || label == "計" || label == "差引計" { return true }
        if isGrandTotalLabel(label) || isRestatementOrSectionTotalLabel(label) { return true }
        if label.contains("控除") { return true }
        if usgaapYearRowPattern.firstMatch(
            in: label, range: NSRange(label.startIndex..., in: label)) != nil {
            return true
        }
        if label.hasSuffix("年度以降") { return true }
        return false
    }

    private static func isUSGAAPComparisonTable(_ table: Element) -> Bool {
        let text = (try? table.text()) ?? ""
        if text.contains("前") && text.contains("当") { return true }
        let range = NSRange(text.startIndex..., in: text)
        if usgaapDatePattern.numberOfMatches(in: text, range: range) >= 2 { return true }
        if usgaapFiscalTermPattern.numberOfMatches(in: text, range: range) >= 2 { return true }
        return false
    }

    private static func parseUSGAAPDebtComparisonTable(_ table: Element) -> [Row]? {
        guard isUSGAAPComparisonTable(table),
              let trs = (try? table.select("tr"))?.array() else { return nil }

        let tableText = (try? table.text()) ?? ""
        let scale: Double = tableText.contains("千円") ? 1_000
            : tableText.contains("億円") ? 100_000_000
            : Financial.millionYen

        var pendingCategory: String?
        var pendingHasDetailRows = false
        var rows: [Row] = []

        for tr in trs {
            guard let cells = (try? tr.select("td, th"))?.array(), !cells.isEmpty else { continue }
            var label = normalizeLabel((try? cells[0].text(trimAndNormaliseWhitespace: true)) ?? "")
            if label.isEmpty, cells.count > 1 {
                label = normalizeLabel((try? cells[1].text(trimAndNormaliseWhitespace: true)) ?? "")
            }
            // 無印小計行の金額がラベルが空のとき金額セルへフォールバックしない（富士フイルム長期表）。
            if XBRLUtils.parseTextblockCellValue(label) != nil { label = "" }

            // スペーサー空セルは無視し、数値または「－」だけを前期/当期スロットとみなす。
            // コマーシャル・ペーパーのように片側が「－」の行は compactMap では1件に見える
            // （富士フイルム S100W3XJ 短期表）。
            var amountSlots: [Double?] = []
            for cell in cells.dropFirst() {
                let raw = (try? cell.text(trimAndNormaliseWhitespace: true)) ?? ""
                if let value = XBRLUtils.parseTextblockCellValue(raw) {
                    amountSlots.append(value)
                } else {
                    let token = normalizeLabel(raw)
                    if ["－", "-", "—", "―"].contains(token) { amountSlots.append(nil) }
                }
            }
            if amountSlots.count < 2 {
                if !label.isEmpty, !isUSGAAPSkipRowLabel(label), !isUSGAAPCurrentPortionLabel(label),
                   !isUSGAAPColumnHeaderLabel(label) {
                    pendingCategory = label
                    pendingHasDetailRows = false
                }
                continue
            }
            let prior = amountSlots[0]
            let current = amountSlots[amountSlots.count - 1]
            guard prior != nil || current != nil else { continue }
            if label.isEmpty || isUSGAAPSkipRowLabel(label) || isUSGAAPColumnHeaderLabel(label) {
                continue
            }

            var useLabel = label
            if let pending = pendingCategory {
                if label.hasPrefix("返済期限") {
                    useLabel = pending
                    pendingHasDetailRows = true
                } else if !pendingHasDetailRows {
                    useLabel = pending
                    pendingCategory = nil
                } else {
                    pendingCategory = nil
                    useLabel = label
                }
            }

            let rate = usgaapSingleRatePercent(in: label)
            rows.append(Row(
                label: displayLabel(for: cleanedUSGAAPLabel(useLabel)),
                current: current.map { $0 * scale },
                prior: prior.map { $0 * scale },
                averageInterestRatePercent: rate
            ))
        }
        return rows.isEmpty ? nil : rows
    }

    private static func cleanedUSGAAPLabel(_ raw: String) -> String {
        var s = raw
        let range = NSRange(s.startIndex..., in: s)
        s = usgaapFootnoteMarkerPattern.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: "")
        if let idx = s.firstIndex(of: ";") { s = String(s[..<idx]) }
        if let idx = s.firstIndex(of: "；") { s = String(s[..<idx]) }
        return normalizeLabel(s)
    }

    private static func usgaapSingleRatePercent(in label: String) -> Double? {
        if label.contains("～") || label.contains("~") { return nil }
        let range = NSRange(label.startIndex..., in: label)
        guard let match = usgaapRateInLabelPattern.firstMatch(in: label, range: range),
              let numRange = Range(match.range(at: 1), in: label) else { return nil }
        return Double(label[numRange])
    }

    private static func parseUSGAAPShortTermFromProse(_ text: String) -> [Row] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = usgaapMillionYenPairPattern.matches(in: text, range: range)
        var rows: [Row] = []
        for match in matches {
            guard match.numberOfRanges >= 4,
                  let labelRange = Range(match.range(at: 1), in: text),
                  let priorRange = Range(match.range(at: 2), in: text),
                  let currentRange = Range(match.range(at: 3), in: text),
                  let label = shortTermProseLabel(String(text[labelRange])),
                  let prior = XBRLUtils.parseTextblockCellValue(String(text[priorRange])),
                  let current = XBRLUtils.parseTextblockCellValue(String(text[currentRange]))
            else { continue }
            rows.append(Row(
                label: displayLabel(for: label),
                current: current * Financial.millionYen,
                prior: prior * Financial.millionYen,
                averageInterestRatePercent: nil
            ))
        }
        return rows
    }

    private static func shortTermProseLabel(_ raw: String) -> String? {
        let n = normalizeLabel(raw)
        guard n.contains("短期借入金") || n.contains("コマーシャル") else { return nil }
        let markers = ["金融サービス", "その他の銀行借入", "短期借入金", "コマーシャル"]
        for marker in markers {
            if let r = n.range(of: marker) {
                return String(n[r.lowerBound...])
            }
        }
        return n
    }

    private static func mergeConsecutiveSameLabels(_ rows: [Row]) -> [Row] {
        var merged: [Row] = []
        for row in rows {
            if let last = merged.last, last.label == row.label {
                merged[merged.count - 1] = Row(
                    label: last.label,
                    current: sumOptional(last.current, row.current),
                    prior: sumOptional(last.prior, row.prior),
                    averageInterestRatePercent: nil
                )
            } else {
                merged.append(row)
            }
        }
        return merged
    }

    private static func sumOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        default: return (a ?? 0) + (b ?? 0)
        }
    }

    /// トヨタ自動車 S100Y8NY 実データ検証（2026-08-04）: `ifrsInterestBearingLiabilitiesTextblockTag`は
    /// `parseIFRSNotesTable`の前/当比較表探索では解決できない（ロールフォワード形式のため）。
    /// 同じタグを`parseRollforwardEndingBalancePairTables`で再解析する。
    private static func parseRollforwardNote(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        guard let html = XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsInterestBearingLiabilitiesTextblockTag),
              let soup = try? SwiftSoup.parse(html) else { return nil }
        return parseRollforwardEndingBalancePairTables(in: soup)
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

    /// 財務諸表注記取り込み `borrowings_schedule` note_type 向け。`extract` と異なり
    /// 平均利率も保持したまま行を返す（IBD 合算には使わない生の明細表データ）。
    /// US-GAAP は附属明細表タグがクロスリファレンスのみのため、巨大注記 HTML を追加で読む。
    static func extractRows(xbrlDir: URL) -> (rows: [Row], totalCurrent: Double?, totalPrior: Double?)? {
        parseTable(xbrlDir: xbrlDir) ?? parseUSGAAPNotesTable(xbrlDir: xbrlDir)
    }
}
