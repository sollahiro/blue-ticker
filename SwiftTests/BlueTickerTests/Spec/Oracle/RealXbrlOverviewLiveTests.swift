// Overview の本番キー（`OPENROUTER_OVERVIEW_API_KEY`）での実 XBRL 生成。
// smoke 固定11社（`SmokeTests` / `BreakdownSmokeOracleSupport.smokeDocs` と同じ docID）。
// 数字混入なし・だ・である調。50〜80字は目安。文面は非決定なのでオラクル凍結しない。
// `BLT_OVERVIEW_LIVE_DUMP` があれば JSON 一覧を書く（golden ではない）。

import Foundation
import Testing

@testable import BlueTickerCore

struct OverviewSmokeCompany: Sendable {
    let code: String
    let name: String
    let sector: String
    let docID: String
}

@Suite struct RealXbrlOverviewLiveTests {
    /// `BreakdownSmokeOracleSupport.smokeDocs` と同じ11社。社名は生成プロンプト用。
    private static let companies: [OverviewSmokeCompany] = [
        .init(code: "2802", name: "味の素株式会社", sector: "食料品", docID: "S100VXJA"),
        .init(code: "2871", name: "株式会社ニチレイ", sector: "食料品", docID: "S100VYA0"),
        .init(code: "3490", name: "株式会社アズ企画設計", sector: "不動産業", docID: "S100VU4O"),
        .init(code: "4901", name: "富士フイルムホールディングス株式会社", sector: "化学", docID: "S100W3XJ"),
        .init(code: "6103", name: "オークマ株式会社", sector: "機械", docID: "S100W043"),
        .init(code: "6326", name: "株式会社クボタ", sector: "機械", docID: "S100XR0M"),
        .init(code: "7269", name: "スズキ株式会社", sector: "輸送用機器", docID: "S100W4MT"),
        .init(code: "7422", name: "東邦レマック株式会社", sector: "卸売業", docID: "S100XRD8"),
        .init(code: "7751", name: "キヤノン株式会社", sector: "電気機器", docID: "S100XTLJ"),
        .init(
            code: "8306", name: "株式会社三菱ＵＦＪフィナンシャル・グループ", sector: "銀行業",
            docID: "S100W4FB"),
        .init(
            code: "8316", name: "株式会社三井住友フィナンシャルグループ", sector: "銀行業",
            docID: "S100W0S7"),
    ]

    private static var liveKeyAvailable: Bool {
        guard let key = ProcessInfo.processInfo.environment[companyOverviewAPIKeyEnv],
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return resolveOverviewLLMEndpoint() != nil
    }

    @Test(
        .enabled(if: liveKeyAvailable, "OPENROUTER_OVERVIEW_API_KEY not available"),
        .timeLimit(.minutes(10))
    )
    func liveGenerateSmoke11() async throws {
        let endpoint = try #require(resolveOverviewLLMEndpoint())
        let client = ChatCompletionClient(endpoint: endpoint)
        await SmokeCacheSupport.ensureCached(Self.companies.map(\.docID))

        var rows: [[String: Any]] = []
        for company in Self.companies {
            guard StatementNotesOracleSupport.smokeCacheAvailable(company.docID) else {
                TestVerboseLog.print("SKIP \(company.code) \(company.docID): XBRL キャッシュなし")
                Issue.record("\(company.code): XBRL キャッシュなし")
                continue
            }
            let dir = StatementNotesOracleSupport.smokeXbrlDir(company.docID)
            let sourceText = DescriptionOfBusinessExtractor.extract(in: dir)
            #expect(!sourceText.contains("【関係会社の状況】"), "\(company.code)")
            #expect(!sourceText.contains("【従業員の状況】"), "\(company.code)")

            let input = CompanyOverviewInput(
                code: company.code, name: company.name, sector: company.sector,
                docID: company.docID, sourceText: sourceText)
            let draft = await CompanyOverviewGenerator.generate(
                input: input, client: client, model: endpoint.model)

            TestVerboseLog.print(
                "\(company.code)\t\(company.docID)\tok=\(draft.ok)\tchars=\(draft.charCount)\t"
                    + "attempts=\(draft.attempts)\t\(draft.overview)"
            )
            if !draft.okDetail.isEmpty {
                TestVerboseLog.print("\(company.code) ok_detail=\(draft.okDetail)")
            }

            rows.append([
                "code": company.code,
                "name": company.name,
                "sector": company.sector,
                "doc_id": company.docID,
                "input_chars": draft.inputCharsTotal,
                "input_thin": draft.inputThin,
                "applicable": draft.applicable,
                "ok": draft.ok,
                "ok_detail": draft.okDetail,
                "char_count": draft.charCount,
                "attempts": draft.attempts,
                "clipped": draft.clipped,
                "overview": draft.overview,
            ])

            if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                #expect(!draft.applicable, "\(company.code): 空入力なのに applicable")
                #expect(draft.attempts == 0, "\(company.code): 空入力なのにモデルを呼んだ")
                continue
            }
            #expect(draft.attempts >= 1, "\(company.code)")
            #expect(draft.applicable, "\(company.code)")
            #expect(draft.ok, "\(company.code): \(draft.okDetail) overview=\(draft.overview)")
            #expect(draft.charCount > 0, "\(company.code)")
            #expect(draft.charCount <= companyOverviewMaxChars, "\(company.code)")
            #expect(
                CompanyOverviewRules.evaluate(
                    applicable: draft.applicable, overview: draft.overview) == .ok,
                "\(company.code)")
            #expect(!draft.overview.contains(company.code), "\(company.code)")
        }

        if let dump = ProcessInfo.processInfo.environment["BLT_OVERVIEW_LIVE_DUMP"], !dump.isEmpty {
            let payload: [String: Any] = [
                "set": "smoke11",
                "golden": false,
                "model": endpoint.model,
                "companies": rows,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: dump))
            TestVerboseLog.print("wrote \(dump)")
        }
        #expect(rows.count == Self.companies.count)
    }
}
