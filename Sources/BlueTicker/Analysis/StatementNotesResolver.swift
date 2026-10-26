// 財務諸表注記取り込み: 財務取り込み・内訳取り込み・Statement取り込み が対象外の財務諸表注記（Statement Notes）を note_type ごとに解決する。
// note_type ごとの決定論ロジックをこの1ファイルに集約する（種別×別ファイルは過剰。
// plan「Resolver: StatementNotesResolver.swift」参照）。
//

import Foundation
import SwiftSoup

enum StatementNotesResolver {

    /// IBD計算用CF補足（`borrowings_schedule` note_type）。
    ///
    /// 連結附属明細表「借入金等明細表」の構成科目（短期借入金・社債・長期借入金・リース負債等）を
    /// 当期首/当期末残高・平均利率つきで表として公開する。解析ロジックは
    /// `BorrowingsSchedule.extractRows`（J-GAAP/IFRS は `IBDExtractor` が使う `extract` と表探索を
    /// 共有。US-GAAP は巨大注記 HTML を `extractRows` のみが読む）を再利用し、自前で明細表を
    /// 再パースしない。合計行は `isTotal: true` で区別する（平均利率は「－」表記のため nil）。
    ///
    /// v2（2026-08-02）: 当初は当期末残高のみ `items: [StatementLineItem]` で返していたが、実データ
    /// レビュー（ユーザー、SOMPO S100R1LR）で平均利率・当期首残高も欲しいとの要望があり、
    /// `BorrowingsComponentPayload` へ切り出した（単一値の `StatementLineItem` では複数値を表現
    /// できないため）。返済期限（表の5列目）はユーザー判断で対象外（フリーテキストで構造化コストが
    /// 見合わない）。
    /// v3（2026-08-12）: US-GAAP 連結は附属明細表タグがクロスリファレンスのみのため見送りだったが、
    /// `NotesToConsolidatedFinancialStatementsUSGAAPTextBlock` の注記表／散文から内訳を取る。
    /// 個別 BS への silent fallback はしない。オペレーティング・リースは IBD / `lease_liabilities` 側。
    static func resolveBorrowingsSchedule(xbrlDir: URL) -> StatementNoteResolveResult {
        guard let result = BorrowingsSchedule.extractRows(xbrlDir: xbrlDir) else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        var components: [BorrowingsComponentPayload] = result.rows.compactMap { row in
            guard row.current != nil || row.prior != nil else { return nil }
            return BorrowingsComponentPayload(
                label: row.label, priorBalance: row.prior, currentBalance: row.current,
                averageInterestRatePercent: row.averageInterestRatePercent)
        }
        if result.totalCurrent != nil || result.totalPrior != nil {
            components.append(
                BorrowingsComponentPayload(
                    label: "合計", priorBalance: result.totalPrior, currentBalance: result.totalCurrent,
                    averageInterestRatePercent: nil, isTotal: true))
        }
        guard !components.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        let hash = components.map {
            "\($0.label)=\($0.priorBalance ?? -1),\($0.currentBalance ?? -1),\($0.averageInterestRatePercent ?? -1)"
        }.joined(separator: ";")
        return .resolved(
            payload: StatementNotePayload(borrowingsComponents: components),
            source: statementNoteSourceXbrlFacts, contentHash: hash)
    }

    /// リース負債（`lease_liabilities` note_type）。
    ///
    /// **notes は IFRS TextBlock 注記のみを resolved にする**（実データ検証 2026-08-12、smoke 固定11社）。
    /// 連結 BS の構造化タグ（`LeaseLiabilities*IFRS` / `LeaseObligations*`）は `statement` と同じ
    /// 値になるため本 note では採用しない。
    ///
    /// 1. IFRS リース注記 TextBlock（`IFRSLease` の TextBlock 経路。**BS HTML・BS タグは使わない**）。
    /// 2. BS にリース負債タグ当期値あり → `available_via_statement`。
    /// 3. US-GAAP → `us_gaap_unsupported`（連結は HTML 経路で、`fieldSetFromInstant` の
    ///    構造化タグ判定では statement 案内ができない。PPE と同型）。
    /// 4. それ以外 → `not_found`。
    /// 旧 4（借入金等明細表のリース債務 → `available_via_notes`）は公開先 note を廃止したので
    /// `not_found` に倒す。IBD は `.resolved` のときだけこの結果をゲートに使う。
    static func resolveLeaseLiabilities(xbrlDir: URL) -> StatementNoteResolveResult {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let accountingStandard = detectAccountingStandard(tagElements)
        let fieldSet = fieldSetFromInstant(tagElements)

        // TextBlock があるときだけ IFRSLease を呼ぶ。fieldSet は空渡しでパターンA（BSタグ）をスキップ。
        let hasIFRSTextblock =
            XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsLeasesTextblockTag)
            != nil
        if hasIFRSTextblock {
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir)
            var textblockItems: [StatementLineItem] = []
            for (order, component) in lease.components.enumerated() {
                guard let current = component.current else { continue }
                textblockItems.append(
                    StatementLineItem(
                        tag: Xbrl.ifrsLeasesTextblockTag, label: component.label, value: current,
                        unit: "yen", order: order))
            }
            if textblockItems.isEmpty, let current = lease.current {
                textblockItems.append(
                    StatementLineItem(
                        tag: Xbrl.ifrsLeasesTextblockTag, label: "リース負債", value: current,
                        unit: "yen", order: 0))
            }
            let baseOrder = textblockItems.count
            for (offset, bucket) in lease.maturityBuckets.enumerated() {
                guard let current = bucket.current else { continue }
                textblockItems.append(
                    StatementLineItem(
                        tag: Xbrl.ifrsLeasesTextblockTag, label: bucket.label, value: current,
                        unit: "yen", order: baseOrder + offset))
            }
            if !textblockItems.isEmpty {
                return resolvedLeaseLiabilities(items: textblockItems)
            }
        }

        let hasBSLeaseTag = Xbrl.leaseLiabilitiesBSTags.contains {
            resolveItem(fieldSet, tags: [$0]).current != nil
        }
        if hasBSLeaseTag {
            return .notApplicable(reason: statementNoteNotApplicableAvailableViaStatement)
        }
        if accountingStandard == "US-GAAP" {
            return .notApplicable(reason: statementNotApplicableUSGAAP)
        }
        return .notApplicable(reason: statementNoteNotApplicableNotFound)
    }

    private static func resolvedLeaseLiabilities(items: [StatementLineItem]) -> StatementNoteResolveResult {
        let hash = items.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// 販売費及び一般管理費の主要な費目内訳（`sga_expense_breakdown` note_type）。
    ///
    /// 連結損益計算書関係注記の構造化タグから決定論で抽出する（`docs/statement.md`）。
    /// breakdown `research_and_development`（発生支出）とは別物。販管費から引いて残差を作らない。
    ///
    /// 実データ検証（2026-08-27）:
    /// - オークマ S100YFQC: `*SGA`（運賃荷造費・研究開発費 2,097 等）。発生支出 4,265 と
    ///   セグメントののれん償却は除外
    /// - アズ企画 S100VU4O: `*SGA`
    /// - スズキ S100YFG2: `*SGAIFRS` + `ResearchAndDevelopmentExpenditureRecognizedAsExpenseDuringPeriodIFRS`
    ///   （271,082。発生支出 270,400 とは別）。合計は開示 SGA と一致
    /// - 味の素 S100VXJA: 販売費・一般管理費を分けた IFRS 注記タグ（別掲 R&D は費目に入れない）
    /// - 東邦レマック S100XRD8: 非連結のみ → `fieldSetFromDuration` の単体フォールバック
    /// - SMFG S100W0S7: 個別注記のみ（連結に費目タグ無し）→ `not_found`
    /// - クボタ S100XR0M: 連結に費目タグ無し（個別のみ）→ `not_found`
    /// - US-GAAP → `us_gaap_unsupported`
    static func resolveSgaExpenseBreakdown(xbrlDir: URL) -> StatementNoteResolveResult {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let accountingStandard = detectAccountingStandard(tagElements)
        if accountingStandard == "US-GAAP" {
            return .notApplicable(reason: statementNotApplicableUSGAAP)
        }

        let durationFS = fieldSetFromDuration(tagElements)

        let hasCombinedSGAIFRSComponents = durationFS.contains { tag, fv in
            fv.current != nil && tag.hasSuffix("SGAIFRS")
                && !Xbrl.sgaExpenseBreakdownExcludedTags.contains(tag)
                && !Xbrl.sgaExpenseBreakdownTotalTags.contains(tag)
        }

        var componentTags: [String] = []
        var totalTags: [String] = []
        for (tag, fv) in durationFS {
            guard fv.current != nil else { continue }
            if Xbrl.sgaExpenseBreakdownTotalTags.contains(tag) {
                totalTags.append(tag)
                continue
            }
            if isSgaExpenseBreakdownComponentTag(
                tag, hasCombinedSGAIFRSComponents: hasCombinedSGAIFRSComponents
            ) {
                componentTags.append(tag)
            }
        }
        guard !componentTags.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        let isSplitSellingAndGA =
            totalTags.contains("SellingExpensesIFRS")
            || totalTags.contains("GeneralAndAdministrativeExpensesIFRS")

        let wantedTags = Set(componentTags + totalTags)
        let labelsByTag = sgaExpenseBreakdownLabels(xbrlDir: xbrlDir, tags: wantedTags)

        var items: [StatementLineItem] = []
        for tag in componentTags.sorted() {
            guard let value = durationFS[tag]?.current else { continue }
            items.append(
                StatementLineItem(
                    tag: tag, label: labelsByTag[tag], value: value, unit: "yen", order: nil,
                    section: sgaExpenseBreakdownSection(
                        for: tag, isSplitSellingAndGA: isSplitSellingAndGA),
                    isTotal: false))
        }
        for tag in totalTags.sorted() {
            guard let value = durationFS[tag]?.current else { continue }
            items.append(
                StatementLineItem(
                    tag: tag, label: labelsByTag[tag], value: value, unit: "yen", order: nil,
                    section: sgaExpenseBreakdownSection(
                        for: tag, isSplitSellingAndGA: isSplitSellingAndGA),
                    isTotal: true))
        }
        guard items.contains(where: { !$0.isTotal }) else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        let hash = items.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// 日本語ラベル。標準タクソノミ／提出パッケージの lab を優先し、無ければ当期 fact が載る
    /// `<tr>` 先頭の日本語セルを使う（`assets/taxonomy` 未配置の CI / Cloud でも床が揃う）。
    private static func sgaExpenseBreakdownLabels(
        xbrlDir: URL, tags: Set<String>
    ) -> [String: String] {
        let taxonomyLabels = XBRLUtils.loadLabelsByTag(in: xbrlDir)
        let htmlLabels = sgaExpenseBreakdownHtmlRowLabels(xbrlDir: xbrlDir, tags: tags)
        var result: [String: String] = [:]
        for tag in tags {
            if let taxonomy = taxonomyLabels[tag], !taxonomy.isEmpty {
                result[tag] = taxonomy
                continue
            }
            if let html = htmlLabels[tag], !html.isEmpty {
                result[tag] = refineSgaExpenseBreakdownHtmlLabel(tag: tag, htmlLabel: html)
            }
        }
        return result
    }

    /// 当期 Duration fact（連結優先、無ければ個別）を含む表行から日本語ラベルを拾う。
    /// SwiftSoup 経由だと inline XBRL 属性が欠落することがあるため、生 HTML を正規表現で走査する。
    private static func sgaExpenseBreakdownHtmlRowLabels(
        xbrlDir: URL, tags: Set<String>
    ) -> [String: String] {
        var consolidated: [String: String] = [:]
        var nonconsolidated: [String: String] = [:]
        let factPattern = sgaNonFractionPattern
        let ctxPattern = sgaContextRefPattern
        let cellPattern = sgaTableCellPattern

        for file in sgaExpenseBreakdownHtmlFiles(in: xbrlDir) {
            guard let raw = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let ns = NSRange(raw.startIndex..., in: raw)
            for fact in factPattern.matches(in: raw, range: ns) {
                guard let attrsRange = Range(fact.range(at: 1), in: raw) else { continue }
                let attrs = String(raw[attrsRange])
                let attrsNS = NSRange(attrs.startIndex..., in: attrs)
                guard let tag = ixbrlFactLocalName(fromAttributes: attrs),
                      let ctxMatch = ctxPattern.firstMatch(in: attrs, range: attrsNS),
                      let ctxRange = Range(ctxMatch.range(at: 1), in: attrs)
                else { continue }
                guard tags.contains(tag) else { continue }
                let ctx = String(attrs[ctxRange])
                let isCons = ContextHelpers.isConsolidatedDuration(ctx)
                let isNonCons = ContextHelpers.isNonConsolidatedDuration(ctx)
                guard isCons || isNonCons else { continue }
                if isCons, consolidated[tag] != nil { continue }
                if isNonCons, nonconsolidated[tag] != nil || consolidated[tag] != nil {
                    continue
                }

                guard let factRange = Range(fact.range, in: raw) else { continue }
                let before = raw[..<factRange.lowerBound]
                guard let trStart = before.range(of: "<tr", options: [.backwards, .caseInsensitive])
                else { continue }
                guard let trEnd = raw.range(
                    of: "</tr>", options: [.caseInsensitive],
                    range: factRange.lowerBound..<raw.endIndex)
                else { continue }
                let row = String(raw[trStart.lowerBound..<trEnd.upperBound])
                guard let label = sgaExpenseBreakdownLabelFromRowHTML(row, cellPattern: cellPattern)
                else { continue }
                if isCons {
                    consolidated[tag] = label
                } else {
                    nonconsolidated[tag] = label
                }
            }
        }
        var merged = consolidated
        for (tag, label) in nonconsolidated where merged[tag] == nil {
            merged[tag] = label
        }
        return merged
    }

    /// セグメント注記の表で、当期のセグメント member context を持つ数値 fact の行名（tag → 行名集合）。
    /// 販管費明細の行名（`sgaExpenseBreakdownHtmlRowLabels`）と同じ生 HTML 走査で、context の
    /// 絞り込みだけが違う（連結/個別の当期 Duration ではなく、当期 Duration × セグメント member）。
    /// 会社がセグメント表で「セグメント利益」と書いた行のタグを知るために使う
    /// （`BreakdownNormalizer.segmentProfitTag`）。
    static func segmentNoteRowLabels(xbrlDir: URL) -> [String: Set<String>] {
        var labels: [String: Set<String>] = [:]
        for file in sgaExpenseBreakdownHtmlFiles(in: xbrlDir) {
            guard let raw = try? String(contentsOf: file, encoding: .utf8),
                  raw.contains("SegmentsMember") || raw.contains("SegmentMember")
            else { continue }
            let ns = NSRange(raw.startIndex..., in: raw)
            for fact in sgaNonFractionPattern.matches(in: raw, range: ns) {
                guard let attrsRange = Range(fact.range(at: 1), in: raw) else { continue }
                let attrs = String(raw[attrsRange])
                let attrsNS = NSRange(attrs.startIndex..., in: attrs)
                guard let tag = ixbrlFactLocalName(fromAttributes: attrs),
                      let ctxMatch = sgaContextRefPattern.firstMatch(in: attrs, range: attrsNS),
                      let ctxRange = Range(ctxMatch.range(at: 1), in: attrs)
                else { continue }
                let ctx = String(attrs[ctxRange])
                guard ctx.hasPrefix("CurrentYearDuration"), ctx.contains("Segment") else { continue }
                guard let factRange = Range(fact.range, in: raw) else { continue }
                let before = raw[..<factRange.lowerBound]
                guard let trStart = before.range(of: "<tr", options: [.backwards, .caseInsensitive]),
                      let trEnd = raw.range(
                        of: "</tr>", options: [.caseInsensitive],
                        range: factRange.lowerBound..<raw.endIndex)
                else { continue }
                let row = String(raw[trStart.lowerBound..<trEnd.upperBound])
                guard let label = sgaExpenseBreakdownLabelFromRowHTML(
                    row, cellPattern: sgaTableCellPattern)
                else { continue }
                labels[tag, default: []].insert(label)
            }
        }
        return labels
    }

    /// inline XBRL（`.htm` / `.html`）を優先し、無ければ通常の XBRL インスタンスも見る。
    private static func sgaExpenseBreakdownHtmlFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var html: [URL] = []
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return XBRLUtils.findXbrlFiles(in: dir)
        }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "htm" || ext == "html" {
                html.append(url)
            }
        }
        return html.isEmpty ? XBRLUtils.findXbrlFiles(in: dir) : html
    }

    /// iXBRL `name` 属性のローカル名。EDINET の会社拡張接頭辞は
    /// `jpcrp030000-asr_E03855-000:BusinessIncome` のようにハイフンを含むため、
    /// `\w+:` ではコロンまで進めずタグを落としてしまう。
    static func ixbrlFactLocalName(fromAttributes attrs: String) -> String? {
        let attrsNS = NSRange(attrs.startIndex..., in: attrs)
        guard let nameMatch = sgaFactNamePattern.firstMatch(in: attrs, range: attrsNS),
              let nameRange = Range(nameMatch.range(at: 1), in: attrs)
        else { return nil }
        return String(attrs[nameRange])
    }

    private static let sgaNonFractionPattern = try! NSRegularExpression(
        pattern: #"<ix:nonFraction\b([^>]*)>"#,
        options: [.caseInsensitive])
    private static let sgaFactNamePattern = try! NSRegularExpression(
        pattern: #"name\s*=\s*["'](?:[^"':]+:)?([A-Za-z][A-Za-z0-9]*)["']"#)
    private static let sgaContextRefPattern = try! NSRegularExpression(
        pattern: #"contextRef\s*=\s*["']([^"']+)["']"#)
    private static let sgaTableCellPattern = try! NSRegularExpression(
        pattern: #"<t[dh]\b[^>]*>(.*?)</t[dh]>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// 表行 HTML の先頭付近にある日本語科目名セル（金額・単位・年度見出しは除外）。
    private static func sgaExpenseBreakdownLabelFromRowHTML(
        _ row: String, cellPattern: NSRegularExpression
    ) -> String? {
        let ns = NSRange(row.startIndex..., in: row)
        for match in cellPattern.matches(in: row, range: ns) {
            guard let bodyRange = Range(match.range(at: 1), in: row) else { continue }
            var cleaned = String(row[bodyRange])
            cleaned = cleaned.replacingOccurrences(
                of: #"<[^>]+>"#, with: "", options: .regularExpression)
            cleaned = cleaned.htmlEntityDecoded
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            guard cleaned.unicodeScalars.contains(where: {
                (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
            }) else { continue }
            if cleaned.contains("年度") || cleaned.hasPrefix("自") || cleaned.hasPrefix("至") {
                continue
            }
            let numericLike = cleaned
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "，", with: "")
                .replacingOccurrences(of: "百万円", with: "")
                .replacingOccurrences(of: "千円", with: "")
                .replacingOccurrences(of: "〃", with: "")
                .replacingOccurrences(of: "△", with: "")
                .replacingOccurrences(of: "−", with: "")
                .replacingOccurrences(of: "－", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            if numericLike.isEmpty || Double(numericLike) != nil { continue }
            return cleaned
        }
        return nil
    }

    /// HTML 行ラベルが「合計」だけのとき、合計タグ種別に応じた科目名へ置き換える。
    private static func refineSgaExpenseBreakdownHtmlLabel(tag: String, htmlLabel: String) -> String {
        let bare = ["合計", "計", "小計"].contains(htmlLabel)
        guard bare else { return htmlLabel }
        switch tag {
        case "SellingExpensesIFRS": return "販売費"
        case "GeneralAndAdministrativeExpensesIFRS": return "一般管理費"
        case "SellingGeneralAndAdministrativeExpenses",
            "SellingGeneralAndAdministrativeExpensesIFRS":
            return "販売費及び一般管理費"
        default: return htmlLabel
        }
    }

    /// 販管費費目タグかどうか。合計行・発生支出・TextBlock/Abstract は除外。
    private static func isSgaExpenseBreakdownComponentTag(
        _ tag: String, hasCombinedSGAIFRSComponents: Bool
    ) -> Bool {
        if tag.hasSuffix("TextBlock") || tag.hasSuffix("Abstract") { return false }
        if Xbrl.sgaExpenseBreakdownExcludedTags.contains(tag) { return false }
        if Xbrl.sgaExpenseBreakdownTotalTags.contains(tag) { return false }
        if tag.hasSuffix("SGA") || tag.hasSuffix("SGAIFRS") { return true }
        if tag.hasSuffix("SellingExpensesIFRS") { return true }
        if tag.hasSuffix("GAIFRS") { return true }
        if Xbrl.sgaExpenseBreakdownIFRSComponentTags.contains(tag) { return true }
        if tag == Xbrl.sgaExpenseBreakdownIFRSRdInSGATag {
            return hasCombinedSGAIFRSComponents
        }
        return false
    }

    /// 味の素型（販売費／一般管理費分離）向けの `section`。結合販管費（スズキ等）は nil。
    /// `*SGAIFRS` は `hasSuffix("GAIFRS")` にも当たるため、結合タグを先に除外する。
    private static func sgaExpenseBreakdownSection(
        for tag: String, isSplitSellingAndGA: Bool
    ) -> StatementLineSection? {
        if tag.hasSuffix("SGA") || tag.hasSuffix("SGAIFRS") { return nil }
        if tag == "SellingExpensesIFRS" || tag.hasSuffix("SellingExpensesIFRS") {
            return .group("selling")
        }
        if tag == "GeneralAndAdministrativeExpensesIFRS" || tag.hasSuffix("GAIFRS") {
            return .group("general_and_administrative")
        }
        if isSplitSellingAndGA, Xbrl.sgaExpenseBreakdownIFRSComponentTags.contains(tag) {
            return .group("selling")
        }
        return nil
    }

    /// IFRS注記に共通の「資産区分ごとに正味帳簿価額・取得原価・累計償却/減損の3タグが揃う」構造から
    /// 正味帳簿価額タグだけを抽出する共通処理（PPE・のれん双方で使う）。
    ///
    /// 実データ検証（2026-08-02、トヨタ S100VWVY）: 「取得原価」「累計償却/減損」を示す
    /// キーワード（`AcquisitionCost`/`AccumulatedDepreciation`/`AccumulatedAmortization`/
    /// `AccumulatedImpairment`）の後に付く語尾は会社により揺れる（トヨタの
    /// `VehiclesAndEquipmentOnOperatingLeasesAccumulatedDepreciationAndImpairmentIFRS` は
    /// 「Losses」が無く固定サフィックス完全一致では除外できなかった）。除外判定はサフィックス
    /// 完全一致ではなくキーワードの部分一致にする（トヨタはPPE区分ごとに正味帳簿価額タグ自体を
    /// 持たず取得原価・累計償却の2タグのみのため、修正後は本note_typeが正しく notApplicable になる）。
    /// 1株当たり情報（`per_share_information` note_type）。
    ///
    /// 実データ検証（2026-08-02）: EPS・潜在株式調整後EPS・BPSはいずれも「業績等の概要
    /// （SummaryOfBusinessResults）」の離散数値タグから決定論で取得できる（注記本体のHTML
    /// テーブルはパースしない）。EPSは既存 `PerShareExtractor.extract`（`Xbrl.basicEpsTags`）を
    /// そのまま再利用する（重複ロジック回避）。BPSは現行会計基準の Summary を優先する。
    /// IFRSは`EquityToAssetRatioIFRSSummaryOfBusinessResults`（タグ名誤り、`unitRef=JPYPerShares`
    /// で判別、日立 S100QZT0「１株当たり親会社株主持分」ラベルと完全一致を確認済み）を先に見る。
    /// US-GAAPは`EquityAttributableToOwnersOfParentPerShareUSGAAPSummaryOfBusinessResults`
    /// （2026-08-11 smoke確認: 富士フイルム S100W3XJ=2779.50・キヤノン S100XTLJ=3974.81、
    /// HTMLラベル「１株当たり株主資本」）。JGAAPは`NetAssetsPerShareSummaryOfBusinessResults`。
    /// IFRS移行年度は日本基準比較表に `NetAssetsPerShare` の CurrentYearInstant が残る
    /// （スズキ S100W4MT: 日本基準第159期 1,404.09。連結の正本は IFRS 表の
    /// 「１株当たり親会社所有者帰属持分」1,539.78。2026-08-19 開示HTML照合）。
    /// カバレッジ実測（キャッシュ144件）: EPS 144/144、BPS 142/144（US-GAAP連結BPSタグ未対応時）、
    /// 潜在株式調整後EPS 65/144（希薄化効果のある証券が無く注記自体に希薄化後EPSを持たない企業は欠落OK、
    /// 2026-08-11 ユーザー確認）。
    ///
    /// 前期比較値は持たない。`company_statement_notes` はdocID（＝1事業年度）単位でingestされる
    /// ため、前期値は前期docIDの`value`で取得できる（財務取り込み `years[]` と同型、ユーザー判断
    /// 2026-08-02）。
    static func resolvePerShareInformation(xbrlDir: URL) -> StatementNoteResolveResult {
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTagElements)
        let instantFS = fieldSetFromInstant(allTagElements)

        var items: [StatementLineItem] = []

        if let eps = PerShareExtractor.extract(durationFS: durationFS, tagElements: allTagElements).eps {
            items.append(
                StatementLineItem(tag: "eps", label: "１株当たり当期純利益", value: eps, unit: "yen_per_share", order: nil))
        }
        if let diluted = resolveItem(durationFS, tags: Xbrl.dilutedEpsTags).current {
            items.append(
                StatementLineItem(
                    tag: "diluted_eps", label: "潜在株式調整後１株当たり当期純利益", value: diluted,
                    unit: "yen_per_share", order: nil))
        }
        if let bps = resolveEquityPerShareIFRSMislabeled(xbrlDir: xbrlDir) {
            items.append(
                StatementLineItem(
                    tag: "bps", label: "１株当たり親会社株主持分", value: bps, unit: "yen_per_share", order: nil))
        } else if let bps = resolveItem(instantFS, tags: Xbrl.equityPerShareUSGAAPTags).current {
            items.append(
                StatementLineItem(
                    tag: "bps", label: "１株当たり株主資本", value: bps, unit: "yen_per_share", order: nil))
        } else if let bps = resolveItem(instantFS, tags: Xbrl.netAssetsPerShareTags).current {
            items.append(
                StatementLineItem(tag: "bps", label: "１株当たり純資産額", value: bps, unit: "yen_per_share", order: nil))
        }

        guard !items.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        let hash = items.sorted { $0.tag < $1.tag }.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// IFRS企業の「1株当たり親会社株主持分」相当値。EDINETタクソノミ上は
    /// `EquityToAssetRatioIFRSSummaryOfBusinessResults`（自己資本比率）という誤った名前だが、
    /// `unitRef` が1株当たり金額（`JPYPerShares` / 外貨建て開示の `USDPerShares`）の場合のみ実体は金額
    /// （実データ確認済み）。US-GAAP企業では同名タグが `unitRef=pure`（真の比率、0〜1）で使われるため、
    /// unitRef を見ずにタグ名だけで判定してはならない（実データ確認済み: 小松製作所 S100QYNI）。
    /// 外貨建て開示が邦貨併記で円の値も持つときは、fact 収集が開示通貨の値を残す（6269 S100XU6C）。
    private static func resolveEquityPerShareIFRSMislabeled(xbrlDir: URL) -> Double? {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        guard let fact = facts["EquityToAssetRatioIFRSSummaryOfBusinessResults"]?["CurrentYearInstant"],
              AmountUnit.isPerShare(unitRef: fact.unitRef)
        else { return nil }
        return fact.value
    }

    /// 設備投資等の概要（`capital_expenditures_overview` note_type）。
    ///
    /// 実データ検証（2026-08-02）: 単一セグメント企業（レーザーテック S100JRT9）は注記が自由記述の
    /// 文章のみで、総額タグ（`Xbrl.capexOverviewTags`）1本が唯一の数値源。複数セグメント企業
    /// （日立 S100QZT0）は注記HTML内にセグメント名・設備投資金額・前年度比・主な内容/目的の4列
    /// テーブルを持つ。セグメント別の設備投資金額自体は `CapitalExpendituresOverviewOfCapitalExpendituresEtc`
    /// タグにセグメントmember付きcontextでも構造化されているが、前年度比・主な内容/目的はタグ化
    /// されておらずHTML表にしか無いため、表がある場合は表を正として解析する（構造化タグと
    /// 二重に読まず、表の抽出結果に一本化する）。表が無ければ単一値へフォールバックする。
    static func resolveCapitalExpendituresOverview(xbrlDir: URL) -> StatementNoteResolveResult {
        if let segments = parseCapexTable(xbrlDir: xbrlDir), !segments.isEmpty {
            let hash = segments.map { "\($0.segmentName ?? "-")=\($0.investmentAmount ?? -1)" }
                .joined(separator: ";")
            return .resolved(
                payload: StatementNotePayload(capexSegments: segments),
                source: statementNoteSourceXbrlFacts, contentHash: hash)
        }

        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTagElements)
        guard let total = resolveItem(durationFS, tags: Xbrl.capexOverviewTags).current else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        let segment = CapexSegmentPayload(
            segmentName: nil, investmentAmount: total, yoyPercent: nil, description: nil)
        return .resolved(
            payload: StatementNotePayload(capexSegments: [segment]),
            source: statementNoteSourceXbrlFacts, contentHash: "\(total)")
    }

    /// `OverviewOfCapitalExpendituresEtcTextBlock` 内のセグメント別テーブルをパースする。
    /// セグメント表が無ければ nil。金額単位は表内の「億円」「百万円」「千円」から判定し、
    /// 単位だけの注記表が先にある場合は後続表へ継承する。会社ごとの列数・rowspan/colspan
    /// 揺れは `gridRows`＋ヘッダー文言ベースの列分類で吸収（固定列位置にしない）。
    /// ヘッダーから分類できない表のみ旧来フォールバック。個別設備一覧は除外し総額タグへ。
    /// 会社別の揺れ・回帰は smoke/golden（経緯は Git）。
    private static func parseCapexTable(xbrlDir: URL) -> [CapexSegmentPayload]? {
        guard let html = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: "OverviewOfCapitalExpendituresEtcTextBlock"),
            let soup = try? SwiftSoup.parse(html),
            let tables = (try? soup.select("table"))?.array()
        else { return nil }

        var inheritedScale: Double?
        for table in tables {
            let rows = gridRows(from: table)
            if let scale = capexTableScale(rows) { inheritedScale = scale }
            guard let scale = inheritedScale else { continue }

            let headerRowCount = rows.prefix(while: { isCapexHeaderRow($0) }).count
            let headerRows = rows.prefix(headerRowCount)
            // 「会社名・事業所名／所在地」列を持つ表はセグメント別内訳ではなく個別設備一覧
            // （オークマ S100W043、富士フイルム S100W3XJ の後続表）。主な設備の抜粋であり総額の
            // 内訳ではないため除外する
            let headerCells = headerRows.flatMap { $0 }
            if headerCells.contains(where: {
                $0.contains("会社名") || $0.contains("事業所名") || $0.contains("所在地")
            }) { continue }

            // ヘッダー文言から列を分類する（複数段見出しは同じ列の文言を連結して判定）
            var colHeader: [Int: String] = [:]
            for row in headerRows {
                for (i, cell) in row.enumerated() where !cell.isEmpty {
                    colHeader[i, default: ""] += " " + cell
                }
            }
            var nameCols: [Int] = []
            var currentCols: [Int] = []
            var amountCols: [Int] = []
            var yoyCols: [Int] = []
            var descCols: [Int] = []
            for (i, h) in colHeader {
                if h.contains("％") || h.contains("%") {
                    yoyCols.append(i)
                } else if h.contains("比") {
                    // 「前期比」が差額（百万円）の会社（ニチレイ）があるため、％表記でない
                    // 比較列は yoyPercent に入れない
                    continue
                } else if h.contains("前"), h.contains("期") || h.contains("年度") {
                    continue  // 前期列は payload にフィールドがなく、金額列候補からも外す
                } else if h.contains("当"), h.contains("期") || h.contains("年度") {
                    currentCols.append(i)
                } else if h.contains("設備投資") || h.contains("投資額") || h.contains("金額") {
                    amountCols.append(i)
                } else if h.contains("名称") || h.contains("セグメント") {
                    nameCols.append(i)
                } else if h.contains("内容") || h.contains("目的") {
                    descCols.append(i)
                }
            }
            // 当期列が特定できたらそこだけを使う。なければ汎用の金額列。どちらも無ければ
            // 旧フォールバック（行内の最初の数値=金額）
            let primaryAmountCols = (currentCols.isEmpty ? amountCols : currentCols).sorted()

            var segments: [CapexSegmentPayload] = []
            for cols in rows.dropFirst(headerRowCount) {
                guard !cols.isEmpty else { continue }
                let amount: Double
                let amountIdx: Int
                var yoy: Double?
                var description: String?
                if !primaryAmountCols.isEmpty {
                    var found: (idx: Int, value: Double)?
                    for i in primaryAmountCols where i < cols.count {
                        if let v = XBRLUtils.parseTextblockCellValue(cols[i]) {
                            found = (i, v)
                            break
                        }
                    }
                    guard let f = found else { continue }  // 金額欄が「―」等の行は飛ばす
                    amount = f.value
                    amountIdx = f.idx
                    for i in yoyCols where i < cols.count {
                        if let v = XBRLUtils.parseTextblockCellValue(cols[i]) { yoy = v; break }
                    }
                    if !descCols.isEmpty {
                        description = descCols.lazy.filter { $0 < cols.count }.map { cols[$0] }
                            .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                    }
                } else {
                    guard let idx = cols.firstIndex(where: {
                        XBRLUtils.parseTextblockCellValue($0) != nil
                    }), idx > 0
                    else { continue }
                    amountIdx = idx
                    amount = XBRLUtils.parseTextblockCellValue(cols[idx])!
                    let after = Array(cols[(idx + 1)...])
                    if let first = after.first, let v = XBRLUtils.parseTextblockCellValue(first) {
                        yoy = v
                        description = after.count > 1 ? after[1] : nil
                    } else {
                        description = after.first
                    }
                }
                // セグメント名: 名称列が分類できていればその末尾側を優先する（ソフトバンクGは
                // 「報告セグメント」区分見出しが名称列の手前に rowspan で入るため、先頭を取ると
                // 区分見出しをセグメント名と誤認する）。分類できなければ金額列より左の最初の
                // 非数値セルを使う
                var name: String?
                if !nameCols.isEmpty {
                    name = nameCols.sorted().reversed().lazy.filter { $0 < cols.count }
                        .map { cols[$0] }
                        .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                }
                if name == nil, amountIdx > 0 {
                    name = cols[..<amountIdx]
                        .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                }
                guard let name else { continue }
                if description == nil, descCols.isEmpty, !primaryAmountCols.isEmpty {
                    // 説明列が分類できなかった表向けの従来互換フォールバック（金額列より右の
                    // 最初の非数値セル）。YoY列は数値なのでここには来ない
                    description = cols[(amountIdx + 1)...]
                        .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                }
                if let d = description, d.isEmpty || ["－", "-", "—", "―"].contains(d) {
                    description = nil
                }
                let normalizedName = name.replacingOccurrences(of: "　", with: "").replacingOccurrences(
                    of: " ", with: "")
                // 「計」で終わる行（合計・小計・報告セグメント計等）は他行の集約であり、
                // 個別セグメントとして加算すると二重集計になる（実データ検証: 神戸製鋼所 S100QYHM
                // の「報告セグメント計」が鉄鋼アルミ〜電力7segmentの小計だった）。segmentNameは
                // ラベルのまま保持し、isTotalで集約行だと分かるようにする。
                let isTotal = normalizedName.hasSuffix("計")
                segments.append(
                    CapexSegmentPayload(
                        segmentName: name, investmentAmount: amount * scale, yoyPercent: yoy,
                        description: description, isTotal: isTotal))
            }
            if !segments.isEmpty { return segments }
        }
        return nil
    }

    /// 設備投資表の金額単位。表内のいずれかのセルの単位表記から判定する（大きい単位を優先。
    /// ヘッダー行の「設備投資金額（億円）」のような表記を含む行がデータ行とは限らない
    /// ため、行ではなくセル単位で走査する）。
    private static func capexTableScale(_ rows: [[String]]) -> Double? {
        rows.flatMap { $0 }.compactMap { AmountUnit.yenScale(containedIn: $0)?.multiplier }.max()
    }

    /// 設備投資表の見出し行判定。数値セルを含まず見出し語を含む行を見出しとみなす。
    /// 2段見出し（クボタ S100XR0M の「前年度/当年度」＋「金額（百万円)」）や単位だけの行
    /// （富士フイルム S100W3XJ の「（百万円）」）に対応するため、先頭から連続する限り
    /// すべて見出し行として列分類の材料にする。
    private static func isCapexHeaderRow(_ cols: [String]) -> Bool {
        if cols.contains(where: { XBRLUtils.parseTextblockCellValue($0) != nil }) { return false }
        let joined = cols.joined(separator: " ")
        return [
            "名称", "年度", "会計年度", "金額", "投資額", "設備投資", "内容", "目的",
            "億円", "百万円", "千円", "％", "比",
        ].contains { joined.contains($0) }
    }

    /// 期末の発行済株式総数（`issued_shares_and_capital` note_type。公開面は `shares` の `issued_shares`）。
    /// `PerShareExtractor` と同じタグ解決（【株式の総数等】の普通株式→主要な経営指標等の推移。
    /// financials / smoke の `per_share.issued_shares` と一致）。
    /// 資本金・資本準備金（提出会社単体）と「発行済株式総数、資本金等の推移」の表は読まない
    /// （連結の分析にほとんど使わず、公開もしないため）。タグが無ければ notApplicable。
    static func resolveIssuedSharesAndCapital(xbrlDir: URL) -> StatementNoteResolveResult {
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTagElements)
        guard
            let issuedShares = PerShareExtractor.extract(
                durationFS: durationFS, tagElements: allTagElements
            ).issuedShares
        else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        return .resolved(
            payload: StatementNotePayload(issuedSharesAsOf: IssuedSharesAsOfPayload(issuedShares: issuedShares)),
            source: statementNoteSourceXbrlFacts,
            contentHash: "asOf{s=\(issuedShares)}")
    }

    // MARK: - financials 組立向けパススルー（タスク #1–2、`docs/financials-summary-separation.md`）

    /// `company_financials` 組立が読む EPS。正本は `per_share_information` note（`tag == "eps"`）。
    /// ingest 順序に依存せず、同一 XBRL パス内で `resolvePerShareInformation` を直接呼ぶ（#10b）。
    static func financialsCanonicalEps(xbrlDir: URL) -> Double? {
        guard case .resolved(let payload, _, _) = resolvePerShareInformation(xbrlDir: xbrlDir) else {
            return nil
        }
        return payload.items?.first(where: { $0.tag == "eps" })?.value
    }

    /// `company_financials` 組立が読む BPS。正本は `per_share_information` note（`tag == "bps"`）。
    /// ingest 順序に依存せず、同一 XBRL パス内で `resolvePerShareInformation` を直接呼ぶ（#10b）。
    static func financialsCanonicalBps(xbrlDir: URL) -> Double? {
        guard case .resolved(let payload, _, _) = resolvePerShareInformation(xbrlDir: xbrlDir) else {
            return nil
        }
        return payload.items?.first(where: { $0.tag == "bps" })?.value
    }

    /// `company_financials` 組立が読む発行済株式数。正本は `issued_shares_and_capital` note の
    /// `as_of_period_end.issued_shares`（イベント表の期末残高ではない）。
    static func financialsCanonicalIssuedShares(xbrlDir: URL) -> Double? {
        guard case .resolved(let payload, _, _) = resolveIssuedSharesAndCapital(xbrlDir: xbrlDir) else {
            return nil
        }
        return payload.issuedSharesAsOf?.issuedShares
    }

    /// IFRS 支払利息の notes 正本（`InterestExpensesIFRS` 等＋ TextBlock）。
    /// PL の `FinanceCostsIFRS` は使わない。statement で取れた値は組立側が優先する。
    static func financialsCanonicalInterestExpense(xbrlDir: URL) -> Double? {
        let allTags = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let std = detectAccountingStandard(allTags)
        guard std == "IFRS" else { return nil }
        var durationFS = fieldSetFromDuration(allTags)
        durationFS["FinanceCostsIFRS"] = nil
        return InterestExpenseExtractor.extract(
            fieldSet: durationFS, accountingStandard: std, xbrlDir: xbrlDir
        ).current
    }

    /// `<table>` の各 `<tr>` を `rowspan`/`colspan` を展開した仮想グリッド（列固定・欠損セルなし）
    /// へ変換する。`colspan` は結合された各列へ同じテキストを複製する（実データ検証: ニチレイ
    /// S100VYA0 の設備投資表はヘッダーの「前/当連結会計年度」が colspan=2 で空白の整形列を
    /// またぐため、展開しないとヘッダー文言とデータ列の位置が対応しない）。
    private static func gridRows(from table: Element) -> [[String]] {
        guard let trs = (try? table.select("tr"))?.array() else { return [] }
        var pending: [Int: (text: String, remaining: Int)] = [:]
        var result: [[String]] = []
        for tr in trs {
            guard let tds = (try? tr.select("td"))?.array() else { continue }
            var cols: [String] = []
            var col = 0
            var cellIdx = 0
            while true {
                if let p = pending[col], p.remaining > 0 {
                    cols.append(p.text)
                    pending[col] = p.remaining == 1 ? nil : (p.text, p.remaining - 1)
                    col += 1
                    continue
                }
                guard cellIdx < tds.count else { break }
                let td = tds[cellIdx]
                let text = (try? td.text(trimAndNormaliseWhitespace: true)) ?? ""
                let rowspan = Int((try? td.attr("rowspan")) ?? "") ?? 1
                let colspan = Int((try? td.attr("colspan")) ?? "") ?? 1
                for _ in 0..<colspan {
                    cols.append(text)
                    if rowspan > 1 { pending[col] = (text, rowspan - 1) }
                    col += 1
                }
                cellIdx += 1
            }
            result.append(cols)
        }
        return result
    }
}
