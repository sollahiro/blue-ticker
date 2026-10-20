// statement-notes / shares 404 `reason` の公開契約（既知コード一覧）。

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

        // 公開面（get-shares）が出す reason は既知コードの部分集合で、すべて説明に載っている。
        #expect(allSharesNotApplicableReasons == ["not_found"])
        let skill = try #require(apiSkill(id: "get-shares"))
        for reason in allSharesNotApplicableReasons {
            #expect(isKnownStatementNoteNotApplicableReason(reason))
            #expect(
                skill.description.contains(reason) || skill.instructions.contains(reason),
                "get-shares must document reason \(reason)")
        }
    }

    @Test func sharedUSGAAPReasonMatchesStatementContract() {
        #expect(statementNotApplicableUSGAAP == "us_gaap_unsupported")
        #expect(isKnownStatementNoteNotApplicableReason(statementNotApplicableUSGAAP))
    }
}
