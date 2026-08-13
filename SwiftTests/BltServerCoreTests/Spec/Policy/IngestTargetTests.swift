// `--stages` CSV のパース仕様を検証する。未指定＝全対象、部分選択、不正入力＝nil。

import Testing

@testable import BltServerCore

@Suite("parseIngestTargets")
struct IngestTargetTests {
    @Test("未指定は全対象")
    func nilSelectsAll() {
        #expect(parseIngestTargets(nil) == Set(IngestTarget.allCases))
    }

    @Test("単一対象を選択")
    func singleTarget() {
        #expect(parseIngestTargets("financials") == [.financials])
        #expect(parseIngestTargets("filing-sections") == [.filingSections])
        #expect(parseIngestTargets("breakdowns") == [.breakdowns])
        #expect(parseIngestTargets("statements") == [.statements])
        #expect(parseIngestTargets("statement-notes") == [.notes])
    }

    @Test("複数対象をカンマ区切りで選択")
    func multipleTargets() {
        #expect(parseIngestTargets("financials,filing-sections") == [.financials, .filingSections])
        #expect(
            parseIngestTargets(
                "financials,filing-sections,breakdowns,statements,statement-notes,icons")
                == Set(IngestTarget.allCases))
    }

    @Test("前後空白と重複を許容する")
    func whitespaceAndDuplicates() {
        #expect(parseIngestTargets(" financials , filing-sections ") == [.financials, .filingSections])
        #expect(parseIngestTargets("statements,statements") == [.statements])
    }

    @Test("旧数値トークンと未知トークンは nil")
    func legacyAndUnknownTokensAreNil() {
        for token in ["3", "4", "4half", "5", "6", "7", "financials,4", "foo"] {
            #expect(parseIngestTargets(token) == nil)
        }
    }

    @Test("有効トークンが 0 個なら nil")
    func emptySelectionIsNil() {
        #expect(parseIngestTargets("") == nil)
        #expect(parseIngestTargets(",") == nil)
        #expect(parseIngestTargets(" ") == nil)
    }
}

@Suite("parseStatementNoteTypes")
struct StatementNoteTypesParseTests {
    @Test("未指定は全 note_type（nil）")
    func nilSelectsAll() {
        #expect(parseStatementNoteTypes(nil) == nil)
    }

    @Test("単一 note_type")
    func singleType() {
        #expect(parseStatementNoteTypes("borrowings_schedule") == ["borrowings_schedule"])
    }

    @Test("複数 note_type")
    func multipleTypes() {
        let selected = parseStatementNoteTypes(
            "per_share_information,borrowings_schedule,lease_liabilities")
        #expect(selected == [
            "per_share_information", "borrowings_schedule", "lease_liabilities",
        ])
    }

    @Test("未知トークンは nil")
    func unknownTokenIsNil() {
        #expect(parseStatementNoteTypes("dividends,foo") == nil)
    }

    @Test("空選択は nil")
    func emptyIsNil() {
        #expect(parseStatementNoteTypes("") == nil)
    }
}
