import Foundation

struct CompanyRef: Hashable, Identifiable, Codable {
    var code: String
    var name: String
    var sector: String
    var iconURL: String?

    var id: String { code }

    init(code: String, name: String, sector: String, iconURL: String? = nil) {
        self.code = code
        self.name = name
        self.sector = sector
        self.iconURL = iconURL
    }

    init(_ hit: CompanyHit) {
        code = hit.code
        name = hit.name
        sector = hit.sector ?? ""
        iconURL = hit.iconURL
    }

    init(_ item: FeedTrendItem) {
        code = item.code
        name = item.name
        sector = item.sector ?? ""
        iconURL = item.iconURL
    }

    /// RSS に業種は無い。銘柄面が `financials` の `sector` で補う。
    init(_ item: FeedRSS.Item) {
        code = item.code
        name = item.name
        sector = ""
        iconURL = item.iconURL
    }

    init(_ watched: WatchedCompany) {
        code = watched.code
        name = watched.name
        sector = watched.sector
        iconURL = watched.iconURL
    }

    init(_ item: ScreenItem) {
        code = item.code
        name = item.name
        sector = item.sector ?? ""
        iconURL = nil
    }
}
