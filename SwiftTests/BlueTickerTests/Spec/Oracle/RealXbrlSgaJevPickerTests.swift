// 業種タグ／1行フォールバックを外したうえで Jev ピッカーが同じ sga を拾うこと、
// およびタグ経路の end-to-end Summary が変わらないこと。
//
// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、無ければ SKIP。

import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct RealXbrlSgaJevPickerTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private let million = 1_000_000.0

    private struct Case {
        var docID: String
        var sga: Double
        var label: String?
        var pickContains: String
    }

    /// タグ経路で既に埋まっている書類。ピッカーは業種／1行タグを外して同じ値を返す。
    private static let pickerGoldens: [Case] = [
        .init(docID: "S100YGFW", sga: 147_511, label: "供給販売費及び一般管理費", pickContains: "供給販売費"),
        .init(docID: "S100YGOL", sga: 38_568, label: "供給販売費及び一般管理費", pickContains: "供給販売費"),
        .init(docID: "S100YEHM", sga: 24_778, label: "供給販売費及び一般管理費", pickContains: "供給販売費"),
        .init(docID: "S100YE54", sga: 68_805, label: "供給販売費及び一般管理費", pickContains: "供給販売費"),
        .init(docID: "S100YIW6", sga: 21_282, label: "供給販売費及び一般管理費", pickContains: "供給販売費"),
        .init(docID: "S100XTA9", sga: 33_773, label: "供給販売費及び一般管理費", pickContains: "供給販売費"),
        .init(docID: "S100XTDX", sga: 31_074, label: "供給販売費及び一般管理費", pickContains: "供給販売費"),
        .init(docID: "S100YCN8", sga: 8_458, label: "一般管理費", pickContains: "一般管理費"),
        .init(docID: "S100YHI4", sga: 2_185, label: "一般管理費", pickContains: "一般管理費"),
        .init(docID: "S100YIQY", sga: 7_840, label: "一般管理費", pickContains: "一般管理費"),
        .init(docID: "S100YK2X", sga: 912, label: "一般管理費", pickContains: "一般管理費"),
        .init(docID: "S100YJV2", sga: 846, label: "一般管理費", pickContains: "一般管理費"),
        .init(docID: "S100XZ5Y", sga: 369, label: "一般管理費", pickContains: "一般管理費"),
        .init(docID: "S100XAG9", sga: 822, label: "一般管理費", pickContains: "一般管理費"),
        .init(docID: "S100XTOY", sga: 71_964, label: nil, pickContains: "販売費及び一般管理費"),
        .init(docID: "S100YGXR", sga: 421, label: "事業費用", pickContains: "事業費用"),
        .init(docID: "S100YJB4", sga: 3_210, label: "営業費用", pickContains: "営業費用"),
    ]

    private func dir(_ docID: String) async -> URL? {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: Self.xbrlRoot)
        let dir = Self.xbrlRoot.appendingPathComponent("\(docID)_xbrl")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return nil
        }
        return dir
    }

    private func pl(_ dir: URL) -> [StatementLineItem]? {
        guard case .resolved(let year) = StatementAnalyzer.resolveFromXBRL(
            xbrlDir: dir, docID: nil, statementTypes: [.incomeStatement])
        else { return nil }
        return year.incomeStatement
    }

    @Test func pickerMatchesTaggedSummaryWhenIndustryTagsAreDisabled() async throws {
        for fixture in Self.pickerGoldens {
            guard let dir = await dir(fixture.docID) else { continue }
            let tagged = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
            #expect(tagged.sga == fixture.sga * million, "e2e \(fixture.docID)")
            #expect(tagged.sgaLabel == fixture.label, "e2e label \(fixture.docID)")

            let omitted = try #require(
                StatementFinancialsResolver.resolve(
                    xbrlDir: dir, sgaTagPolicy: .omitIndustryAndSingleLine))
            #expect(omitted.sga == nil, "omit tags \(fixture.docID)")

            let items = try #require(pl(dir))
            let picked = await SgaLineJevPicker.pick(
                pl: items,
                decider: FakeSgaLineDecider(pickLabelContains: fixture.pickContains),
                docID: fixture.docID)
            #expect(picked.accepted?.value == fixture.sga * million, "picker \(fixture.docID)")
            #expect(
                SgaLineJevPicker.publishedSgaLabel(picked.accepted?.label) == fixture.label,
                "picker label \(fixture.docID)")
            #expect(picked.audit.applied, "picker applied \(fixture.docID)")

            let overlay = await StatementFinancialsResolver.resolve(
                xbrlDir: dir,
                sgaTagPolicy: .omitIndustryAndSingleLine,
                sgaLineDecider: FakeSgaLineDecider(pickLabelContains: fixture.pickContains))
            #expect(overlay?.sga == fixture.sga * million, "overlay \(fixture.docID)")
            #expect(overlay?.sgaLabel == fixture.label, "overlay label \(fixture.docID)")
        }
    }

    @Test func osakaGasStandardTagUnchangedWithoutJev() async throws {
        guard let dir = await dir("S100YFQT") else { return }
        let v = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(v.sga == 262_706 * million)
        #expect(v.sgaLabel == nil)
        let omitted = try #require(
            StatementFinancialsResolver.resolve(
                xbrlDir: dir, sgaTagPolicy: .omitIndustryAndSingleLine))
        #expect(omitted.sga == 262_706 * million)
        #expect(omitted.sgaJevAudit == nil)
    }

    @Test func japanPostBankWithoutGateFailsClosedOnJev() async throws {
        guard let dir = await dir("S100Y9G1") else { return }
        let tagged = try #require(StatementFinancialsResolver.resolve(xbrlDir: dir))
        #expect(tagged.sga == nil)
        let items = try #require(pl(dir))
        let picked = await SgaLineJevPicker.pick(
            pl: items,
            decider: FakeSgaLineDecider(pickLabelContains: "営業経費"),
            docID: "S100Y9G1")
        #expect(picked.accepted == nil)
        #expect(!picked.audit.applied)
        let overlay = await StatementFinancialsResolver.resolve(
            xbrlDir: dir, sgaLineDecider: FakeSgaLineDecider(pickLabelContains: "営業経費"))
        #expect(overlay?.sga == nil)
    }

    @Test func japanPostBankPathNeverCallsJev() async throws {
        guard let dir = await dir("S100Y9G1") else { return }
        let v = await StatementFinancialsResolver.resolve(
            xbrlDir: dir, edinetIndustry: "銀行業",
            sgaLineDecider: FakeSgaLineDecider(pickLabelContains: "営業経費"))
        #expect(v?.sga == 946_425 * million)
        #expect(v?.sgaLabel == "営業経費")
        #expect(v?.sgaJevAudit == nil)
    }

    @Test func mufgBankGoldenUnchanged() async throws {
        guard let dir = await dir("S100YJQO") else { return }
        let v = try #require(
            StatementFinancialsResolver.resolve(xbrlDir: dir, edinetIndustry: "銀行業"))
        #expect(v.sga == 3_489_570 * million)
        #expect(v.sgaLabel == "営業経費")
        let overlay = await StatementFinancialsResolver.resolve(
            xbrlDir: dir, edinetIndustry: "銀行業",
            sgaLineDecider: FakeSgaLineDecider(pickLabelContains: "営業経費"))
        #expect(overlay?.sga == 3_489_570 * million)
        #expect(overlay?.sgaJevAudit == nil)
    }
}
