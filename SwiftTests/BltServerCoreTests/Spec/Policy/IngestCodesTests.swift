// `--codes` CSV のパース仕様を検証する。未指定＝nil（絞り込みなし）、指定時は空白除去・重複排除。

import Testing

@testable import BltServerCore

@Suite("parseIngestCodes")
struct IngestCodesTests {
    @Test("未指定は nil（絞り込みなし）")
    func nilMeansNoFilter() {
        #expect(parseIngestCodes(nil) == nil)
    }

    @Test("単一コードを選択")
    func singleCode() {
        #expect(parseIngestCodes("7203") == ["7203"])
    }

    @Test("複数コードをカンマ区切りで選択")
    func multipleCodes() {
        #expect(parseIngestCodes("7203,6758") == ["7203", "6758"])
    }

    @Test("前後空白と重複を許容する")
    func whitespaceAndDuplicates() {
        #expect(parseIngestCodes(" 7203 , 6758 ") == ["7203", "6758"])
        #expect(parseIngestCodes("7203,7203") == ["7203"])
    }

    @Test("有効トークンが 0 個なら空集合（nil ではない）")
    func emptySelectionIsEmptySet() {
        #expect(parseIngestCodes("") == [])
        #expect(parseIngestCodes(",") == [])
        #expect(parseIngestCodes(" ") == [])
    }
}
