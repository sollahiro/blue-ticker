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
        #expect(parseIngestTargets("half-financials") == [.halfFinancials])
        #expect(parseIngestTargets("filing-sections") == [.filingSections])
        #expect(parseIngestTargets("breakdowns") == [.breakdowns])
        #expect(parseIngestTargets("statements") == [.statements])
    }

    @Test("複数対象をカンマ区切りで選択")
    func multipleTargets() {
        #expect(parseIngestTargets("financials,filing-sections") == [.financials, .filingSections])
        #expect(
            parseIngestTargets("filing-sections,financials,half-financials")
                == [.filingSections, .financials, .halfFinancials])
        #expect(
            parseIngestTargets("financials,half-financials,filing-sections,breakdowns,statements")
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
