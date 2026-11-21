import Foundation
import SwiftData

@Model
final class WatchedCompany {
    /// CloudKit 同期のため、非 Optional は既定値を持つ。
    var code: String = ""
    var name: String = ""
    var sector: String = ""
    var iconURL: String?
    var addedAt: Date = Date.now
    /// リスト全体の並び。小さいほど上。
    var sortOrder: Int = 0

    init(
        code: String,
        name: String,
        sector: String,
        iconURL: String? = nil,
        addedAt: Date = .now,
        sortOrder: Int = 0
    ) {
        self.code = code
        self.name = name
        self.sector = sector
        self.iconURL = iconURL
        self.addedAt = addedAt
        self.sortOrder = sortOrder
    }

    /// 同じ銘柄の行は1つだけ残す（並びが上の行）。旧版の口座別の行を畳む。
    static func removeDuplicateCodes(_ items: [WatchedCompany], in context: ModelContext) {
        var seen: Set<String> = []
        for item in items.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if seen.insert(item.code).inserted { continue }
            context.delete(item)
        }
    }

    /// 検索（`/v1/companies`）の最新の応答で、保存済みの業種・アイコン URL・社名を更新する。
    /// 保存時の値を描き続けると、サーバー側でアイコンや業種が変わっても追従しない。
    /// 応答に無い項目（`nil` / 空）では既存の値を消さない。変わったときだけ書く（CloudKit 同期の無駄打ち回避）。
    /// 戻り値は変更があったかどうか。
    @discardableResult
    func refresh(from hit: CompanyHit) -> Bool {
        guard hit.code == code else { return false }
        var changed = false
        if let url = hit.iconURL, !url.isEmpty, url != iconURL {
            iconURL = url
            changed = true
        }
        if let newSector = hit.sector, !newSector.isEmpty, newSector != sector {
            sector = newSector
            changed = true
        }
        if !hit.name.isEmpty, hit.name != name {
            name = hit.name
            changed = true
        }
        return changed
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
}
