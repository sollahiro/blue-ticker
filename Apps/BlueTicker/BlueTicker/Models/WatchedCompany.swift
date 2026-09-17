import Foundation
import SwiftData

@Model
final class WatchedCompany {
    var code: String
    var name: String
    var sector: String
    var iconURL: String?
    var addedAt: Date
    /// リスト全体の並び。小さいほど上。
    var sortOrder: Int = 0
    /// 株数。取得単価と揃って初めて保有。
    var quantity: Double?
    /// 取得単価（円/株）。株数と揃って初めて保有。
    var acquisitionPriceYen: Double?
    var broker: String?
    var accountType: String?

    init(
        code: String,
        name: String,
        sector: String,
        iconURL: String? = nil,
        addedAt: Date = .now,
        sortOrder: Int = 0,
        quantity: Double? = nil,
        acquisitionPriceYen: Double? = nil,
        broker: String? = nil,
        accountType: String? = nil
    ) {
        self.code = code
        self.name = name
        self.sector = sector
        self.iconURL = iconURL
        self.addedAt = addedAt
        self.sortOrder = sortOrder
        self.quantity = quantity
        self.acquisitionPriceYen = acquisitionPriceYen
        self.broker = broker
        self.accountType = accountType
    }

    var isHolding: Bool {
        FundMath.isHolding(quantity: quantity, acquisitionPriceYen: acquisitionPriceYen)
    }

    var kindLabel: String {
        isHolding ? "保有" : "ウォッチ"
    }

    var accountCaption: String? {
        let parts = [broker, accountType]
            .compactMap { Self.nonEmpty($0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 株数・単価・証券会社・口座がすべて空。リスト追加だけの行。
    var isBlankHoldingsRow: Bool {
        quantity == nil && acquisitionPriceYen == nil && accountCaption == nil
    }

    /// 同じ銘柄に保有があるウォッチ行は削除する（追加中の空行は残す）。
    static func pruneBlankRowsCoveredByHoldings(
        _ items: [WatchedCompany],
        keeping addedIDs: Set<PersistentIdentifier> = [],
        in context: ModelContext
    ) {
        let codesWithHoldings = Set(items.filter(\.isHolding).map(\.code))
        for item in items where !item.isHolding && codesWithHoldings.contains(item.code) {
            if addedIDs.contains(item.persistentModelID) { continue }
            context.delete(item)
        }
    }

    var listCaption: String {
        var parts = [kindLabel]
        if isHolding {
            parts.append(Format.shares(quantity))
        }
        return parts.joined(separator: " · ")
    }

    func duplicateAccountRow(sortOrder: Int) -> WatchedCompany {
        WatchedCompany(
            code: code,
            name: name,
            sector: sector,
            iconURL: iconURL,
            sortOrder: sortOrder
        )
    }

    /// 選択式。未選択（空白）も保有入力できる。
    static let brokerChoices = [
        "SBI証券",
        "楽天証券",
        "マネックス証券",
        "松井証券",
        "三菱UFJ eスマート証券",
        "野村證券",
        "大和証券",
        "SMBC日興証券",
        "みずほ証券",
        "岡三証券",
        "GMOクリック証券",
        "PayPay証券",
    ]

    static let accountTypeChoices = ["一般", "特定", "NISA"]

    static func choices(_ catalog: [String], including extra: String?) -> [String] {
        var list = catalog
        if let extra = nonEmpty(extra), !list.contains(extra) {
            list.append(extra)
        }
        return list
    }

    static func nextSortOrder(among items: [WatchedCompany]) -> Int {
        (items.map(\.sortOrder).min() ?? 0) - 1
    }

    /// 既存行が全部 0 のときだけ、追加日の新しい順に振り直す。
    static func repairSortOrderIfNeeded(_ items: [WatchedCompany]) {
        guard !items.isEmpty else { return }
        if Set(items.map(\.sortOrder)).count == items.count { return }
        for (index, item) in items.sorted(by: { $0.addedAt > $1.addedAt }).enumerated() {
            item.sortOrder = index
        }
    }

    static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
