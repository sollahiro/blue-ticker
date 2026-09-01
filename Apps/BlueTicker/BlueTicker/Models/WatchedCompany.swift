import Foundation
import SwiftData

@Model
final class WatchedCompany {
    @Attribute(.unique) var code: String
    var name: String
    var sector: String
    var iconURL: String?
    var addedAt: Date

    init(code: String, name: String, sector: String, iconURL: String? = nil, addedAt: Date = .now) {
        self.code = code
        self.name = name
        self.sector = sector
        self.iconURL = iconURL
        self.addedAt = addedAt
    }
}
