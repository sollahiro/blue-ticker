// Overview の本番キー（`OPENROUTER_OVERVIEW_API_KEY`）での実 XBRL 生成。
// 数字混入なし・だ・である調を回帰する。50〜80字は目安で、完成文なら短くてよい。
// 文面は非決定なのでオラクル凍結しない。キーまたは XBRL キャッシュが無ければ SKIP。

import Foundation
import Testing

@testable import BlueTickerCore

struct OverviewSmokeCompany: Sendable, CustomTestStringConvertible {
    let code: String
    let name: String
    let sector: String
    let docID: String
    let keywords: [String]
    var testDescription: String { "\(code) \(docID)" }
}

@Suite struct RealXbrlOverviewLiveTests {
    private static let companies: [OverviewSmokeCompany] = [
        .init(
            code: "7203", name: "トヨタ自動車株式会社", sector: "輸送用機器", docID: "S100Y8NY",
            keywords: ["自動車", "車両", "トラック"]),
        .init(
            code: "8306", name: "株式会社三菱ＵＦＪフィナンシャル・グループ", sector: "銀行業",
            docID: "S100YJQO", keywords: ["銀行", "信託", "証券"]),
        .init(
            code: "6758", name: "ソニーグループ株式会社", sector: "電気機器", docID: "S100YE2C",
            keywords: ["ゲーム", "音楽", "半導体", "映像", "エンタ"]),
        .init(
            code: "2802", name: "味の素株式会社", sector: "食料品", docID: "S100Y992",
            keywords: ["調味料", "アミノ酸", "冷凍"]),
        .init(
            code: "7751", name: "キヤノン株式会社", sector: "電気機器", docID: "S100XTLJ",
            keywords: ["カメラ", "プリンタ", "複合機", "映像", "オフィス"]),
        .init(
            code: "4901", name: "富士フイルムホールディングス株式会社", sector: "化学",
            docID: "S100YIBH", keywords: ["ヘルスケア", "材料", "イメージ", "写真", "メディカル"]),
        .init(
            code: "6098", name: "株式会社リクルートホールディングス", sector: "サービス業",
            docID: "S100YDHL", keywords: ["人材", "求人", "マッチング", "メディア", "販促", "HR"]),
    ]

    private static var liveKeyAvailable: Bool {
        guard let key = ProcessInfo.processInfo.environment[companyOverviewAPIKeyEnv],
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return resolveOverviewLLMEndpoint() != nil
    }

    @Test(
        .enabled(if: liveKeyAvailable, "OPENROUTER_OVERVIEW_API_KEY not available"),
        arguments: companies
    )
    func liveGeneratePassesRules(_ company: OverviewSmokeCompany) async throws {
        await SmokeCacheSupport.ensureCached([company.docID])
        guard StatementNotesOracleSupport.smokeCacheAvailable(company.docID) else {
            TestVerboseLog.print("SKIP \(company.docID): XBRL キャッシュなし")
            return
        }

        let dir = StatementNotesOracleSupport.smokeXbrlDir(company.docID)
        let sourceText = DescriptionOfBusinessExtractor.extract(in: dir)
        #expect(!sourceText.isEmpty)
        #expect(!sourceText.contains("【関係会社の状況】"))
        #expect(!sourceText.contains("【従業員の状況】"))
        #expect(sourceText.count >= companyOverviewInputThinChars)

        let endpoint = try #require(resolveOverviewLLMEndpoint())
        let client = ChatCompletionClient(endpoint: endpoint)
        let input = CompanyOverviewInput(
            code: company.code, name: company.name, sector: company.sector,
            docID: company.docID, sourceText: sourceText)
        let draft = await CompanyOverviewGenerator.generate(
            input: input, client: client, model: endpoint.model)

        TestVerboseLog.print(
            "\(company.code) ok=\(draft.ok) applicable=\(draft.applicable) chars=\(draft.charCount) "
                + "attempts=\(draft.attempts) clipped=\(draft.clipped) overview=\(draft.overview)"
        )
        if !draft.okDetail.isEmpty {
            TestVerboseLog.print("\(company.code) ok_detail=\(draft.okDetail)")
        }

        #expect(draft.attempts >= 1)
        #expect(draft.applicable)
        #expect(draft.ok, "\(company.code): \(draft.okDetail) overview=\(draft.overview)")
        #expect(draft.charCount > 0)
        #expect(draft.charCount <= companyOverviewMaxChars)
        #expect(
            CompanyOverviewRules.evaluate(applicable: draft.applicable, overview: draft.overview)
                == .ok)
        #expect(!draft.overview.contains(company.code))
        #expect(company.keywords.contains(where: { draft.overview.contains($0) }))
    }
}
