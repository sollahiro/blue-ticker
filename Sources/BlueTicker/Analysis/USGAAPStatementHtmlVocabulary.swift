// US-GAAP Statement HTML（`USGAAPStatementHtml`）の表分類・残高・合計語彙。
//
// 見出しゆれは社名 contains ではなく、ここに語を足して潰す（BLT-41）。
// 複合条件（A かつ B、除外）の組み立ては `USGAAPStatementHtml` 側。語そのものはここが正本。

import Foundation

enum USGAAPStatementHtmlVocabulary {

    // MARK: - Generic matchers

    static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    static func hasAnyPrefix(_ haystack: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { haystack.hasPrefix($0) }
    }

    static func hasAnySuffix(_ haystack: String, _ suffixes: [String]) -> Bool {
        suffixes.contains { haystack.hasSuffix($0) }
    }

    // MARK: - Table classification phrases

    /// CF 本表: 営業活動行があれば採用。投資＋財務が揃っても採用（分割表）。
    static let cashFlowOperatingContains = ["営業活動によるキャッシュ・フロー"]
    static let cashFlowInvestingContains = ["投資活動によるキャッシュ・フロー"]
    static let cashFlowFinancingContains = ["財務活動によるキャッシュ・フロー"]

    /// SS 表の資本文脈（セル全文）。信用損失引当金の増減表を除外するための否定語もここ。
    static let equityContextContains = ["純資産", "株主資本", "資本合計", "資本金"]
    static let equityTableExcludeContains = ["信用損失"]

    /// BS 資産表: 部見出し。
    static let assetsSectionContains = ["資産の部"]
    static let assetsSectionExact = ["資産"]
    static let assetsSectionExcludeContains = ["純資産", "負債"]

    /// BS 資産合計行。
    static let assetsTotalExact = ["資産合計"]
    static let assetsTotalSuffix = ["資産合計"]
    static let assetsTotalExcludeContains = ["純資産", "負債"]

    /// BS 負債・純資産表: 部見出し。
    static let liabilitiesSectionContains = ["負債の部", "負債および資本", "負債及び資本"]
    /// グランドトータル行は部見出しではない。
    static let liabilitiesSectionExcludeContains = ["合計"]

    /// BS 負債・純資産表の合計マーカー（表分類用）。
    static let liabilitiesEquityTableNetAssetsTotalContains = ["純資産合計"]
    static let liabilitiesEquityTableLiabilitiesToken = "負債"
    static let liabilitiesEquityTableTotalToken = "合計"

    /// PL 本表マーカー。
    static let salesExact = ["売上高"]
    static let salesSuffix = ["売上高"]
    static let salesContains = ["製品売上高"]
    static let revenueTotalExact = ["収益合計"]
    static let revenueTotalPrefix = ["収益合計"]
    static let revenueTotalExcludeContains = ["控除"]
    static let operatingProfitContains = ["営業利益"]
    static let netIncomeContains = ["当期純利益", "税引前当期純利益"]
    static let ociContains = ["その他の包括利益"]

    // MARK: - Section header phrases (row parsing)

    static let netAssetsSectionContains = ["純資産の部", "資本の部"]
    /// ローマ数字除去後の部見出し（金額なし）。「資本金」とは一致させない。
    static let netAssetsSectionStrippedExact = ["株主資本", "資本"]

    /// 負債と資本を束ねるグランドトータル（section なし）。
    static let liabilitiesAndEquityTotalRequires = ("負債", ["資本", "純資産"])

    // MARK: - Equity balance (SS) phrases

    /// 時系列切り出しマーカー（前期・当期が1表に連続する型）。
    static let equityChronologicalBalanceContains = ["現在残高", "期末現在"]
    /// 日付付き残高（例: YYYY年M月DD日残高）。「日」と「残高」の両方。
    static let equityDateBalanceRequiresBoth = ("日", "残高")

    /// 科目縦 SS の期首/期末（年次切り出しには使わない）。
    static let equityOpenCloseExact = ["期首残高", "期末残高"]
    static let equityOpenClosePrefix = ["期首残高", "期末残高"]

    // MARK: - is_total / CF activity / cash-equivalents tail

    /// 共通の合計・小計。語尾「〜計」一般（累計額 等）は見ない。
    static let totalContains = ["合計", "小計"]
    static let totalExact = ["計"]
    static let totalSuffix = ["費用計", " 計"]

    static let incomeStatementTotalExact = ["営業利益", "売上総利益"]
    static let incomeStatementTotalContains = ["当期純利益", "税引前", "税金等調整前"]

    static let cashFlowActivityContains = ["営業活動", "投資活動", "財務活動"]
    static let cashFlowActivityCashFlowContains = ["キャッシュ・フロー"]
    static let cashFlowActivityCashNetRequiresBoth = ("現金", "純額")

    static let cashFlowTotalContains = ["期首残高", "期末残高", "純減少", "純増減"]

    static let equityTotalExact = ["包括利益"]
    static let equityTotalContains = ["当期包括利益"]

    static let cashEquivalentsContains = ["現金同等物"]
    static let cashEquivalentsTailContains = ["期首残高", "期末残高", "純増減", "純減少", "為替"]

    // MARK: - Meta / header skip phrases

    static let headerExact = ["区分", "注記番号", "注記 番号"]
    static let headerPrefix = ["区分"]
    static let headerAmountContains = ["金額"]
    static let headerAmountUnitContains = ["百万円", "％", "%"]

    static let skipMetaExact = [
        "普通株式", "発行可能株式総数", "発行済株式総数",
        "前連結会計年度", "当連結会計年度",
        "契約債務及び偶発債務",
    ]
    static let skipMetaPrefix = ["（発行", "(発行"]
    static let skipMetaContains = ["自己株式数"]

    // MARK: - Table classification predicates

    static func isCashFlowTable(labels: [String]) -> Bool {
        if labels.contains(where: { containsAny($0, cashFlowOperatingContains) }) {
            return true
        }
        let hasInvesting = labels.contains { containsAny($0, cashFlowInvestingContains) }
        let hasFinancing = labels.contains { containsAny($0, cashFlowFinancingContains) }
        return hasInvesting && hasFinancing
    }

    static func hasEquityContext(_ allCells: String) -> Bool {
        containsAny(allCells, equityContextContains)
    }

    static func isExcludedEquityTable(_ allCells: String) -> Bool {
        containsAny(allCells, equityTableExcludeContains)
    }

    static func isAssetsSectionHeader(_ label: String) -> Bool {
        let t = stripHeaderDecorations(label)
        if containsAny(t, assetsSectionExcludeContains) { return false }
        return containsAny(t, assetsSectionContains) || assetsSectionExact.contains(t)
    }

    static func isAssetsTotalLabel(_ label: String) -> Bool {
        if assetsTotalExact.contains(label) { return true }
        return hasAnySuffix(label, assetsTotalSuffix)
            && !containsAny(label, assetsTotalExcludeContains)
    }

    static func isLiabilitiesSectionHeader(_ label: String) -> Bool {
        let t = stripHeaderDecorations(label)
        if containsAny(t, liabilitiesSectionExcludeContains) { return false }
        return containsAny(t, liabilitiesSectionContains)
    }

    static func isLiabilitiesAndEquityTable(labels: [String]) -> Bool {
        guard labels.contains(where: isLiabilitiesSectionHeader) else { return false }
        if labels.contains(where: { containsAny($0, liabilitiesEquityTableNetAssetsTotalContains) }) {
            return true
        }
        return labels.contains {
            $0.contains(liabilitiesEquityTableLiabilitiesToken)
                && $0.contains(liabilitiesEquityTableTotalToken)
        }
    }

    static func isSalesLabel(_ label: String) -> Bool {
        let s = USGAAPHtml.stripSectionPrefix(label)
        return salesExact.contains(s) || hasAnySuffix(s, salesSuffix) || containsAny(s, salesContains)
    }

    static func isRevenueTotalLabel(_ label: String) -> Bool {
        if revenueTotalExact.contains(label) { return true }
        return hasAnyPrefix(label, revenueTotalPrefix)
            && !containsAny(label, revenueTotalExcludeContains)
    }

    static func isIncomeStatementTable(labels: [String]) -> Bool {
        let hasSales = labels.contains { isSalesLabel($0) }
        let hasRevenueTotal = labels.contains { isRevenueTotalLabel($0) }
        let hasOperatingProfit = labels.contains { containsAny($0, operatingProfitContains) }
        let hasNetIncome = labels.contains { containsAny($0, netIncomeContains) }
        let hasOCI = labels.contains { containsAny($0, ociContains) }
        if hasOCI && !hasSales && !hasRevenueTotal { return false }
        if hasSales && (hasOperatingProfit || hasNetIncome) { return true }
        if hasRevenueTotal && hasNetIncome { return true }
        return false
    }

    // MARK: - Section / balance / total predicates

    static func isNetAssetsSectionHeader(_ label: String) -> Bool {
        let t = stripHeaderDecorations(label)
        if containsAny(t, netAssetsSectionContains) { return true }
        let stripped = USGAAPHtml.stripSectionPrefix(t)
        if netAssetsSectionStrippedExact.contains(stripped) { return true }
        let withoutColon = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
        return netAssetsSectionStrippedExact.contains(withoutColon)
    }

    static func isLiabilitiesAndEquityTotalLabel(_ label: String) -> Bool {
        let t = stripHeaderDecorations(label)
        guard t.contains(liabilitiesEquityTableTotalToken) else { return false }
        let (liab, equityTokens) = liabilitiesAndEquityTotalRequires
        return t.contains(liab) && containsAny(t, equityTokens)
    }

    static func isEquityChronologicalBalanceLabel(_ label: String) -> Bool {
        if containsAny(label, equityChronologicalBalanceContains) { return true }
        if isBareEquityOpenCloseLabel(label) { return false }
        let (day, balance) = equityDateBalanceRequiresBoth
        return label.contains(day) && label.contains(balance)
    }

    static func isBareEquityOpenCloseLabel(_ label: String) -> Bool {
        let s = USGAAPHtml.stripSectionPrefix(label)
        return equityOpenCloseExact.contains(s) || hasAnyPrefix(s, equityOpenClosePrefix)
    }

    static func isEquityBalanceRowLabel(_ label: String) -> Bool {
        isEquityChronologicalBalanceLabel(label) || isBareEquityOpenCloseLabel(label)
    }

    static func isCashFlowActivityTotalLabel(_ s: String) -> Bool {
        guard containsAny(s, cashFlowActivityContains) else { return false }
        if containsAny(s, cashFlowActivityCashFlowContains) { return true }
        let (cash, net) = cashFlowActivityCashNetRequiresBoth
        return s.contains(cash) && s.contains(net)
    }

    static func cfSection(for label: String) -> StatementLineSection? {
        if containsAny(label, cashFlowOperatingContains) { return .operating }
        if containsAny(label, cashFlowInvestingContains) { return .investing }
        if containsAny(label, cashFlowFinancingContains) { return .financing }
        return nil
    }

    static func isCashAndEquivalentsTailRow(_ label: String) -> Bool {
        guard containsAny(label, cashEquivalentsContains) else { return false }
        return containsAny(label, cashEquivalentsTailContains)
    }

    static func isTotalLabel(_ label: String, sectionType: StatementSectionType) -> Bool {
        let s = USGAAPHtml.stripSectionPrefix(label)
        if containsAny(s, totalContains) || totalExact.contains(s) || hasAnySuffix(s, totalSuffix) {
            return true
        }
        switch sectionType {
        case .incomeStatement:
            return incomeStatementTotalExact.contains(s)
                || containsAny(s, incomeStatementTotalContains)
        case .cashFlow:
            return isCashFlowActivityTotalLabel(s) || containsAny(s, cashFlowTotalContains)
        case .changesInEquity:
            return isEquityBalanceRowLabel(s)
                || equityTotalExact.contains(s)
                || containsAny(s, equityTotalContains)
        case .balanceSheet:
            return false
        }
    }

    static func isHeaderLabel(_ label: String) -> Bool {
        if headerExact.contains(label) || hasAnyPrefix(label, headerPrefix) { return true }
        if containsAny(label, headerAmountContains)
            && containsAny(label, headerAmountUnitContains)
        {
            return true
        }
        return false
    }

    static func shouldSkipMetaRow(_ label: String) -> Bool {
        if skipMetaExact.contains(label) { return true }
        if hasAnyPrefix(label, skipMetaPrefix) { return true }
        if containsAny(label, skipMetaContains) { return true }
        if label.allSatisfy({ $0.isNumber || $0 == "," }) { return true }
        return false
    }

    static func stripHeaderDecorations(_ label: String) -> String {
        label.replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }
}
