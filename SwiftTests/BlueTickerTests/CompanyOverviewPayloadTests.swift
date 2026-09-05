// Overview 格納 payload の L0（draft 写経・JSON キー・content_hash）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct CompanyOverviewPayloadTests {
    @Test func payloadCopiesDraftAndDerivesSourceFlags() {
        let overview = "四輪車、二輪車の製造販売を手がける。"
        let draft = CompanyOverviewDraft(
            applicable: true, overview: overview, charCount: overview.count, reason: "",
            ok: true, okDetail: "", clipped: false, attempts: 2,
            model: companyOverviewDefaultModel, inputCharsTotal: 200, inputCharsUsed: 180,
            inputThin: false)
        let payload = CompanyOverviewPayload(draft: draft)
        #expect(payload.overview == overview)
        #expect(payload.charCount == overview.count)
        #expect(payload.attempts == 2)
        #expect(payload.inputCharsUsed == 180)
        #expect(payload.needsReview == false)
        #expect(payload.source == companyOverviewSourceLLM)
        #expect(payload.notApplicableReason == nil)
    }

    @Test func notApplicableAndFailedDraftsSetReviewFlags() {
        let empty = CompanyOverviewPayload(
            draft: CompanyOverviewDraft(
                applicable: false, overview: "", charCount: 0, reason: "empty_source",
                ok: true, okDetail: "", clipped: false, attempts: 0,
                model: companyOverviewDefaultModel, inputCharsTotal: 0, inputCharsUsed: 0,
                inputThin: true))
        #expect(empty.source == companyOverviewSourceNotApplicable)
        #expect(empty.needsReview == false)
        #expect(empty.notApplicableReason == "empty_source")

        let failed = CompanyOverviewPayload(
            draft: CompanyOverviewDraft(
                applicable: true, overview: "短い。", charCount: 3, reason: "",
                ok: false, okDetail: "validation", clipped: false, attempts: 3,
                model: companyOverviewDefaultModel, inputCharsTotal: 10, inputCharsUsed: 10,
                inputThin: true))
        #expect(failed.source == companyOverviewSourceLLM)
        #expect(failed.needsReview == true)
        #expect(failed.notApplicableReason == nil)
    }

    @Test func jsonUsesSnakeCaseKeys() throws {
        let payload = CompanyOverviewPayload(
            applicable: true, overview: "四輪車、二輪車の製造販売を手がける。", charCount: 16,
            reason: "", ok: true, okDetail: "", clipped: true, attempts: 1,
            model: "google/gemini-2.5-flash", inputCharsTotal: 90, inputCharsUsed: 80,
            inputThin: false)
        let data = try JSONEncoder().encode(payload)
        let obj = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["char_count"] as? Int == 16)
        #expect(obj["ok_detail"] as? String == "")
        #expect(obj["input_chars_total"] as? Int == 90)
        #expect(obj["input_chars_used"] as? Int == 80)
        #expect(obj["input_thin"] as? Bool == false)
        #expect(obj["charCount"] == nil)

        let decoded = try JSONDecoder().decode(CompanyOverviewPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func contentHashIsStableAndIgnoresUnrelatedText() {
        let a = companyOverviewContentHash("事業の内容")
        let b = companyOverviewContentHash("事業の内容")
        let c = companyOverviewContentHash("別の本文")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 64)
    }
}
