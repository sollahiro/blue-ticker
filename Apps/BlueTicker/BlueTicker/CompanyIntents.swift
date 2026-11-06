import AppIntents
import Foundation

/// Siri / ショートカット / Spotlight から選べる銘柄。コードで解決し、名前は表示用。
struct CompanyEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "銘柄")
    static let defaultQuery = CompanyEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }

    init(code: String, name: String) {
        id = code
        self.name = name
    }

    init(hit: CompanyHit) {
        self.init(code: hit.code, name: Format.displayName(hit.name, fallback: hit.code))
    }
}

struct CompanyEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CompanyEntity] {
        var result: [CompanyEntity] = []
        for code in identifiers {
            let hits = (try? await APIClient.shared.searchCompanies(query: code)) ?? []
            if let hit = hits.first(where: { $0.code == code }) {
                result.append(CompanyEntity(hit: hit))
            }
        }
        return result
    }

    func entities(matching string: String) async throws -> [CompanyEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let hits = try await APIClient.shared.searchCompanies(query: query)
        return hits.prefix(10).map(CompanyEntity.init(hit:))
    }

    func suggestedEntities() async throws -> [CompanyEntity] { [] }
}

private struct CompanyIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CompanyOverviewIntent: AppIntent {
    static let title: LocalizedStringResource = "会社の概要を見る"
    static let description = IntentDescription("有報から作った会社の概要を返します。")

    @Parameter(title: "銘柄")
    var company: CompanyEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$company)の概要")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response: CompanyOverviewResponse
        do {
            response = try await APIClient.shared.overview(code: company.id)
        } catch {
            throw CompanyIntentError(message: "\(company.name)の概要を取得できませんでした。")
        }
        let text = response.overview
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct CompanyFinancialsIntent: AppIntent {
    static let title: LocalizedStringResource = "会社の最新の業績を見る"
    static let description = IntentDescription("最新の決算期の売上高・営業利益・純利益・ROE を返します。")

    @Parameter(title: "銘柄")
    var company: CompanyEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$company)の最新の業績")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response: FinancialsResponse
        do {
            response = try await APIClient.shared.financials(code: company.id)
        } catch {
            throw CompanyIntentError(message: "\(company.name)の業績を取得できませんでした。")
        }
        guard let year = Format.latestYear(response.years) else {
            throw CompanyIntentError(message: "\(company.name)の業績はまだ集計されていません。")
        }
        let currency = year.currency ?? response.currency
        let text = """
            \(company.name) \(Format.fyJapanese(year.fyEnd))
            売上高 \(Format.autoYen(year.sales, currency: currency))
            営業利益 \(Format.autoYen(year.operatingProfit, currency: currency))
            純利益 \(Format.autoYen(year.netProfit, currency: currency))
            ROE \(Format.percent(year.roe))
            """
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct BlueTickerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompanyOverviewIntent(),
            phrases: [
                "\(.applicationName)で\(\.$company)の概要を教えて",
                "\(.applicationName)で\(\.$company)を調べる",
            ],
            shortTitle: "会社の概要",
            systemImageName: "building.2"
        )
        AppShortcut(
            intent: CompanyFinancialsIntent(),
            phrases: [
                "\(.applicationName)で\(\.$company)の業績を教えて",
                "\(.applicationName)で\(\.$company)の決算を見る",
            ],
            shortTitle: "最新の業績",
            systemImageName: "chart.bar"
        )
    }
}
