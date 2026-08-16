// statement-notes 404 `reason` の公開契約（既知コード一覧）。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct StatementNotesReasonContractTests {
    @Test func knownReasonsAreStableAndDocumentedInApiSkills() throws {
        #expect(
            allStatementNoteNotApplicableReasons == [
                "not_found",
                "available_via_statement",
                "available_via_notes",
                "us_gaap_unsupported",
            ])
        for reason in allStatementNoteNotApplicableReasons {
            #expect(isKnownStatementNoteNotApplicableReason(reason))
        }
        #expect(!isKnownStatementNoteNotApplicableReason("geography_only"))
        #expect(!isKnownStatementNoteNotApplicableReason(""))

        let skill = try #require(apiSkill(id: "get-statement-notes"))
        for reason in allStatementNoteNotApplicableReasons {
            #expect(
                skill.description.contains(reason) || skill.instructions.contains(reason),
                "get-statement-notes must document reason \(reason)")
        }
    }

    @Test func sharedUSGAAPReasonMatchesStatementContract() {
        #expect(statementNotApplicableUSGAAP == "us_gaap_unsupported")
        #expect(isKnownStatementNoteNotApplicableReason(statementNotApplicableUSGAAP))
    }
}
