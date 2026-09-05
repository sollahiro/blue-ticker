// Overview 検証規則（スパイク self-check の L0）。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct CompanyOverviewRulesTests {
    private func ok(_ text: String) -> Bool {
        CompanyOverviewRules.evaluate(applicable: true, overview: text) == .ok
    }

    @Test func acceptsDeAruAndNounStops() {
        let samples = [
            "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスなどを国内海外で提供。",
            "銀行業務、信託銀行業務、証券業務を中心に、カード・リース・資産運用などの幅広い金融サービスを手がける。",
        ]
        for sample in samples {
            #expect(ok(sample), "rejected \(sample.count)字: \(sample)")
        }
    }

    @Test func rejectsDesumasu() {
        let polite =
            "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスなどを国内海外で提供しています。"
        #expect(!ok(polite))
    }

    @Test func rejectsYearCompanySuffixThreeSentencesAndUnfinishedTail() {
        let year = "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスを2026年に提供。"
        #expect(!ok(year))
        let corp = "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスを提供する株式会社。"
        #expect(!ok(corp))
        let many =
            "調味料と冷凍食品などを国内外で提供。医薬用アミノ酸を製造販売する。バイオファーマサービスも手がける。"
        #expect(!ok(many))
        let unfinished =
            "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸などを提供。バイオファーマサービスも手がける"
        #expect(!ok(unfinished))
    }

    @Test func acceptsShortCompleteSentence() {
        let short = "デジタルソフトウェア・アドオンコンテンツの制作・販売、家庭用ゲーム機、音楽制作を手がける。"
        #expect(short.count == 45)
        #expect(ok(short))
    }

    @Test func rejectsEmptyApplicableOverview() {
        #expect(CompanyOverviewRules.evaluate(applicable: true, overview: "") != .ok)
        #expect(CompanyOverviewRules.evaluate(applicable: true, overview: "   ") != .ok)
        #expect(CompanyOverviewRules.evaluate(applicable: true, overview: "。") != .ok)
        #expect(CompanyOverviewRules.evaluate(applicable: true, overview: "！？") != .ok)
        #expect(CompanyOverviewRules.evaluate(applicable: true, overview: "、。") != .ok)
        #expect(CompanyOverviewRules.evaluate(applicable: true, overview: "・・・。") != .ok)
    }

    @Test func applicableFalseRequiresEmptyOverview() {
        #expect(CompanyOverviewRules.evaluate(applicable: false, overview: "") == .ok)
        #expect(CompanyOverviewRules.evaluate(applicable: false, overview: "残文。") != .ok)
    }

    @Test func clipAllowsShortLastSentence() {
        let head = String(repeating: "あ", count: 20) + "。"
        let overflow = String(repeating: "い", count: 80) + "。"
        #expect(head.count < companyOverviewMinChars)
        #expect((head + overflow).count > companyOverviewMaxChars)
        let clipped = CompanyOverviewRules.clip(head + overflow)
        #expect(clipped == head)
        #expect(ok(clipped ?? ""))
    }

    @Test func clipDoesNotCutMidWordWithoutSentenceEnd() {
        #expect(CompanyOverviewRules.clip(String(repeating: "あ", count: 90)) == nil)
    }

    @Test func clipKeepsLastSentenceWithinMax() {
        let head = String(repeating: "あ", count: 55) + "。"
        let tail = String(repeating: "い", count: 40) + "。"
        let clipped = CompanyOverviewRules.clip(head + tail)
        #expect(clipped == head)
        #expect(ok(clipped ?? ""))
    }

    @Test func clipPrefersLaterExclamationOverEarlierStop() {
        let first = String(repeating: "あ", count: 50) + "。"
        let second = String(repeating: "い", count: 20) + "！"
        let overflow = String(repeating: "う", count: 20) + "。"
        #expect(first.count == 51)
        #expect((first + second).count == 72)
        #expect((first + second + overflow).count > companyOverviewMaxChars)
        let clipped = CompanyOverviewRules.clip(first + second + overflow)
        #expect(clipped == first + second)
        #expect(ok(clipped ?? ""))
    }

    @Test func clipPrefersLaterQuestionOverEarlierStop() {
        let first = String(repeating: "あ", count: 50) + "。"
        let second = String(repeating: "い", count: 20) + "？"
        let overflow = String(repeating: "う", count: 20) + "。"
        let clipped = CompanyOverviewRules.clip(first + second + overflow)
        #expect(clipped == first + second)
        #expect(ok(clipped ?? ""))
    }

    @Test func smokeExpectedOverviewsSatisfyRules() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("smoke/overview_mock_expected.json")
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["input_key"] as? String == companyOverviewInputKey)
        #expect(json["xbrl_tag"] as? String == Xbrl.descriptionOfBusinessTextblockTag)
        let companies = try #require(json["companies"] as? [[String: Any]])
        #expect(!companies.isEmpty)
        for row in companies {
            let applicable = try #require(row["applicable"] as? Bool)
            let overview = try #require(row["overview"] as? String)
            #expect(CompanyOverviewRules.evaluate(applicable: applicable, overview: overview) == .ok)
            #expect((row["input_key"] as? String) == companyOverviewInputKey)
        }
    }
}
