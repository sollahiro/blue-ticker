import Foundation

enum CompanyHistory {
    private static let key = "blt.company.history"
    private static let limit = 30

    static func load() -> [CompanyRef] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let items = try? JSONDecoder().decode([CompanyRef].self, from: data)
        else {
            return []
        }
        return items
    }

    static func record(_ company: CompanyRef) {
        var items = load().filter { $0.code != company.code }
        items.insert(company, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
