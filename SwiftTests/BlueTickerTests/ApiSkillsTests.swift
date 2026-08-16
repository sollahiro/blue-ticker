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
        #expect(ids.contains("get-statement"))
    }

    @Test func mcpToolNamesMatchExpectedSet() {
        let names = Set(apiSkillsCatalog().compactMap(\.mcpTool))
        #expect(
            names == [
                "search_companies", "get_filings",
                "get_financial_summary",
                "get_waterfall", "get_filing_content",
                "get_breakdown", "get_statement", "get_statement_notes",
            ])
    }

    @Test func searchCompaniesMapsQueryAliasForMcp() throws {
        let skill = try #require(apiSkill(id: "search-companies"))
        let q = try #require(skill.parameters.first { $0.name == "q" })
        #expect(q.mcpName == "query")
        // REST は省略可、MCP は required（Routes が q 省略を空文字で受ける事実に合わせる）
        #expect(q.required == false)
        #expect(q.effectiveMcpRequired == true)
    }

    @Test func filingContentSectionsTypeDiffersBetweenRestAndMcp() throws {
        let skill = try #require(apiSkill(id: "get-filing-content"))
        let sections = try #require(skill.parameters.first { $0.name == "sections" })
        #expect(sections.type == .string)
        #expect(sections.effectiveMcpType == .stringArray)
        let detail = apiSkillDetailJSON(skill)
        let parameters = try #require(detail["parameters"] as? [[String: Any]])
        let sectionsJSON = try #require(parameters.first { $0["name"] as? String == "sections" })
        #expect(sectionsJSON["type"] as? String == "string")
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

    /// MCP tools/list と REST /v1/skills が共有する description に、未取り込みと非開示の
    /// 区別（reason 有無とコード意味）が載っていること（チャットボットが読み方を知る契約）。
    @Test func statementNotesDescriptionDocumentsReasonSemantics() throws {
        let skill = try #require(apiSkill(id: "get-statement-notes"))
        #expect(skill.description.contains("reason"))
        #expect(skill.description.contains("未取り込み"))
        #expect(skill.description.contains("isError"))
        for reason in allStatementNoteNotApplicableReasons {
            #expect(
                skill.description.contains(reason) || skill.instructions.contains(reason),
                "missing reason \(reason)")
        }
    }
}
