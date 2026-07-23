// ApiSkills カタログの契約: ID 一意・MCP ツール名の対応・REST/MCP パラメータ投影。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct ApiSkillsTests {
    @Test func catalogIdsAreUniqueAndStable() {
        let ids = apiSkillsCatalog().map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("search-companies"))
        #expect(ids.contains("get-breakdown"))
        #expect(ids.contains("list-sectors"))
    }

    @Test func mcpToolNamesMatchExpectedSet() {
        let names = Set(apiSkillsCatalog().compactMap(\.mcpTool))
        #expect(
            names == [
                "search_companies", "search_by_sector", "get_filings",
                "get_financial_summary", "get_half_financial_summary",
                "get_analysis", "get_half_analysis", "get_filing_content",
                "get_breakdown",
            ])
        // REST 専用（MCP なし）
        #expect(apiSkill(id: "list-sectors")?.mcpTool == nil)
    }

    @Test func searchCompaniesMapsQueryAliasForMcp() throws {
        let skill = try #require(apiSkill(id: "search-companies"))
        let q = try #require(skill.parameters.first { $0.name == "q" })
        #expect(q.mcpName == "query")
    }

    @Test func financialsYearsIsRestOnly() throws {
        let skill = try #require(apiSkill(id: "get-financials"))
        let years = try #require(skill.parameters.first { $0.name == "years" })
        #expect(years.mcpName == nil)
    }

    @Test func listAndDetailJSONIncludeSchemaVersion() throws {
        let list = apiSkillsListJSON()
        #expect(list["schema_version"] as? Int == apiSkillsSchemaVersion)
        let skill = try #require(apiSkill(id: "get-filings"))
        let detail = apiSkillDetailJSON(skill)
        #expect(detail["schema_version"] as? Int == apiSkillsSchemaVersion)
        #expect(detail["instructions"] is String)
        #expect(detail["parameters"] is [[String: Any]])
    }
}
