import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension XBRLUtils {
    // MARK: Fact Collection

    /// XMLファイルから {local_tag: {contextRef: XbrlFact}} の辞書を返す。
    static func collectNumericFacts(
        in file: URL,
        allowedTags: Set<String>? = nil,
        nilAsZero: Bool = false,
        labelsByTag: [String: String] = [:],
        rolesByTag: [String: [String]] = [:],
        orderByRoleTag: [String: [String: Int]] = [:],
        periodStartOrderByRoleTag: [String: [String: Int]] = [:],
        periodEndOrderByRoleTag: [String: [String: Int]] = [:]
    ) -> XbrlFactIndex {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let delegate = XBRLNumericsParser(
            allowedTags: allowedTags,
            nilAsZero: nilAsZero,
            labelsByTag: labelsByTag,
            rolesByTag: rolesByTag,
            orderByRoleTag: orderByRoleTag,
            periodStartOrderByRoleTag: periodStartOrderByRoleTag,
            periodEndOrderByRoleTag: periodEndOrderByRoleTag,
            sourceFile: file.lastPathComponent
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    /// XMLファイルから {local_tag: {contextRef: value}} の辞書を返す。
    static func collectNumericElements(
        in file: URL,
        allowedTags: Set<String>? = nil,
        nilAsZero: Bool = false
    ) -> XbrlTagElements {
        factIndexToNumericElements(collectNumericFacts(in: file, allowedTags: allowedTags, nilAsZero: nilAsZero))
    }

}

private final class XBRLNumericsParser: NSObject, XMLParserDelegate {
    var results: XbrlFactIndex = [:]

    /// 同じタグ・同じ context に通貨違いの fact が並ぶもの（外貨建て開示の邦貨併記。三井海洋開発 6269
    /// S100XU6C は主要な経営指標等の BPS を USDPerShares 21.26 と JPYPerShares 3327.57 の両方で持つ）。
    /// 文書末で開示通貨のほうを `results` に残す。
    private var currencyAlternates: [String: [String: [XbrlFact]]] = [:]
    /// 本表タクソノミ（jppfs / jpigp）の金額 fact の通貨ごとの件数。最多を開示通貨とする。
    private var statementCurrencyCounts: [String: Int] = [:]
    private static let statementTaxonomyPrefixes = ["jppfs_cor:", "jpigp_cor:"]
    private var currentQualifiedName = ""

    private let allowedTags: Set<String>?
    private let nilAsZero: Bool
    private let labelsByTag: [String: String]
    private let rolesByTag: [String: [String]]
    private let orderByRoleTag: [String: [String: Int]]
    private let periodStartOrderByRoleTag: [String: [String: Int]]
    private let periodEndOrderByRoleTag: [String: [String: Int]]
    private let sourceFile: String

    private var currentLocalTag = ""
    private var currentCtx = ""
    private var currentText = ""
    private var currentAttrs: [String: String] = [:]
    private var capturing = false

    init(
        allowedTags: Set<String>?,
        nilAsZero: Bool,
        labelsByTag: [String: String],
        rolesByTag: [String: [String]],
        orderByRoleTag: [String: [String: Int]] = [:],
        periodStartOrderByRoleTag: [String: [String: Int]] = [:],
        periodEndOrderByRoleTag: [String: [String: Int]] = [:],
        sourceFile: String
    ) {
        self.allowedTags = allowedTags
        self.nilAsZero = nilAsZero
        self.labelsByTag = labelsByTag
        self.rolesByTag = rolesByTag
        self.orderByRoleTag = orderByRoleTag
        self.periodStartOrderByRoleTag = periodStartOrderByRoleTag
        self.periodEndOrderByRoleTag = periodEndOrderByRoleTag
        self.sourceFile = sourceFile
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        capturing = false
        let localTag = XBRLUtils.localName(of: elementName)
        if let allowed = allowedTags, !allowed.contains(localTag) { return }
        guard let ctx = attributeDict["contextRef"], !ctx.isEmpty else { return }
        currentLocalTag = localTag
        currentQualifiedName = qName ?? elementName
        currentCtx = ctx
        currentText = ""
        currentAttrs = attributeDict
        capturing = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturing else { return }
        capturing = false

        var value = XBRLUtils.parseXbrlValue(currentText)
        if value == nil && nilAsZero {
            let nilVal = currentAttrs["xsi:nil"] ?? currentAttrs["nil"]
            if nilVal?.lowercased() == "true" { value = 0.0 }
        }
        guard let v = value else { return }

        let roles = rolesByTag[currentLocalTag] ?? []
        let sections = roles.map { XBRLUtils.sectionNameFromRole($0) }

        var fact = XbrlFact(
            tag: currentLocalTag,
            contextRef: currentCtx,
            value: v,
            consolidation: XBRLUtils.inferConsolidation(contextRef: currentCtx, roles: roles)
        )
        fact.unitRef = currentAttrs["unitRef"]
        fact.decimals = currentAttrs["decimals"]
        if !roles.isEmpty { fact.role = roles[0]; fact.roles = roles }
        if !sections.isEmpty { fact.section = sections[0]; fact.sections = sections }
        fact.label = labelsByTag[currentLocalTag]
        fact.sourceFile = sourceFile

        var orderByRole: [String: Int] = [:]
        let usePeriodStart =
            ContextHelpers.isConsolidatedPriorInstant(currentCtx)
            || ContextHelpers.isNonConsolidatedPriorInstant(currentCtx)
        let usePeriodEnd =
            ContextHelpers.isConsolidatedInstant(currentCtx)
            || ContextHelpers.isNonConsolidatedInstant(currentCtx)
        for r in roles {
            let resolved: Int?
            if usePeriodStart {
                resolved =
                    periodStartOrderByRoleTag[r]?[currentLocalTag]
                    ?? orderByRoleTag[r]?[currentLocalTag]
            } else if usePeriodEnd {
                resolved =
                    periodEndOrderByRoleTag[r]?[currentLocalTag]
                    ?? orderByRoleTag[r]?[currentLocalTag]
            } else {
                resolved = orderByRoleTag[r]?[currentLocalTag]
            }
            if let o = resolved { orderByRole[r] = o }
        }
        if !orderByRole.isEmpty { fact.orderByRole = orderByRole }

        let currency = AmountUnit.currency(unitRef: fact.unitRef)
        if let currency, !AmountUnit.isPerShare(unitRef: fact.unitRef),
            Self.statementTaxonomyPrefixes.contains(where: { currentQualifiedName.hasPrefix($0) })
        {
            statementCurrencyCounts[currency, default: 0] += 1
        }
        if let currency, let existing = results[currentLocalTag]?[currentCtx],
            let existingCurrency = AmountUnit.currency(unitRef: existing.unitRef),
            existingCurrency != currency
        {
            currencyAlternates[currentLocalTag, default: [:]][currentCtx, default: [existing]].append(fact)
        }
        results[currentLocalTag, default: [:]][currentCtx] = fact
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        guard !currencyAlternates.isEmpty,
            let reporting = statementCurrencyCounts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
        else { return }
        for (tag, byCtx) in currencyAlternates {
            for (ctx, facts) in byCtx {
                if let preferred = facts.last(where: { AmountUnit.currency(unitRef: $0.unitRef) == reporting }) {
                    results[tag]?[ctx] = preferred
                }
            }
        }
    }
}
