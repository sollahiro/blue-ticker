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

    func duplicateAccountRow(sortOrder: Int) -> WatchedCompany {
        WatchedCompany(
            code: code,
            name: name,
            sector: sector,
            iconURL: iconURL,
            sortOrder: sortOrder
        )
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
