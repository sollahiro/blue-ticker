// `--stages` CSV のパース仕様を検証する。未指定＝全ステージ、部分選択、不正入力＝nil。

import Testing

@testable import BltServerCore

@Suite("parseIngestStages")
struct IngestStageTests {
    @Test("未指定は全ステージ")
    func nilSelectsAll() {
        #expect(parseIngestStages(nil) == Set(IngestStage.allCases))
    }

    @Test("単一ステージを選択")
    func singleStage() {
        #expect(parseIngestStages("5") == [.sections])
        #expect(parseIngestStages("4") == [.financials])
        #expect(parseIngestStages("4half") == [.half])
        #expect(parseIngestStages("6") == [.breakdowns])
        #expect(parseIngestStages("7") == [.statement])
    }

    @Test("複数ステージをカンマ区切りで選択")
    func multipleStages() {
        #expect(parseIngestStages("4,5") == [.financials, .sections])
        #expect(parseIngestStages("5,4,4half") == [.sections, .financials, .half])
        #expect(parseIngestStages("5,4,4half,6,7") == Set(IngestStage.allCases))
    }

    @Test("前後空白と重複を許容する")
    func whitespaceAndDuplicates() {
        #expect(parseIngestStages(" 4 , 5 ") == [.financials, .sections])
        #expect(parseIngestStages("5,5") == [.sections])
    }

    @Test("未知トークンを含むと nil")
    func unknownTokenIsNil() {
        #expect(parseIngestStages("9") == nil)
        #expect(parseIngestStages("4,foo") == nil)
    }

    @Test("有効トークンが 0 個なら nil")
    func emptySelectionIsNil() {
        #expect(parseIngestStages("") == nil)
        #expect(parseIngestStages(",") == nil)
        #expect(parseIngestStages(" ") == nil)
    }
}
