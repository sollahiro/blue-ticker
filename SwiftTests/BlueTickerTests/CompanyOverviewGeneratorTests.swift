// Overview 生成。空入力はモデルを呼ばない。ChatCompleting はモック。

import Foundation
import Testing

@testable import BlueTickerCore

private actor ScriptedChat: ChatCompleting {
    private var replies: [Data]
    private(set) var users: [String] = []

    init(replies: [[String: Any]]) throws {
        self.replies = try replies.map { try JSONSerialization.data(withJSONObject: $0) }
    }

    func complete(system: String, user: String, jsonSchema: Data, schemaName: String) async throws -> Data {
        users.append(user)
        guard schemaName == companyOverviewJSONSchemaName else {
            throw ChatCompletionError.decodingFailed("schema \(schemaName)")
        }
        guard !replies.isEmpty else { throw ChatCompletionError.emptyContent }
        return replies.removeFirst()
    }

    func callCount() -> Int { users.count }
}

@Suite struct CompanyOverviewGeneratorTests {
    private func input(_ text: String) -> CompanyOverviewInput {
        CompanyOverviewInput(
            code: "7203", name: "トヨタ自動車株式会社", sector: "輸送用機器", docID: "S100Y8NY",
            sourceText: text)
    }

    private func reply(overview: String, applicable: Bool = true) -> [String: Any] {
        [
            "applicable": applicable,
            "overview": overview,
            "char_count": overview.count,
            "reason": "test",
        ]
    }

    @Test func emptyInputDoesNotCallModel() async throws {
        let client = try ScriptedChat(replies: [reply(overview: "呼ばれてはいけない文。")])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("  "), client: client, model: companyOverviewDefaultModel)
        #expect(draft.applicable == false)
        #expect(draft.overview.isEmpty)
        #expect(draft.attempts == 0)
        #expect(draft.ok)
        #expect(await client.callCount() == 0)
    }

    @Test func acceptsValidFirstReply() async throws {
        let overview = "セダン、ミニバン、SUV、トラック等の自動車とその関連部品・用品の設計、製造、販売を行う。金融事業も手掛ける。"
        let client = try ScriptedChat(replies: [reply(overview: overview)])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("当社は自動車の製造販売を行う。"), client: client,
            model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.applicable)
        #expect(draft.overview == overview)
        #expect(draft.charCount == overview.count)
        #expect(draft.attempts == 1)
        #expect(await client.callCount() == 1)
    }

    @Test func repairsDesumasuWithoutFlippingApplicable() async throws {
        let polite =
            "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスなどを国内海外で提供しています。"
        let fixed =
            "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスなどを国内海外で提供。"
        let client = try ScriptedChat(replies: [
            reply(overview: polite),
            reply(overview: fixed),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("調味料と冷凍食品の製造販売。"), client: client,
            model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.overview == fixed)
        #expect(draft.attempts == 2)
        let users = await client.users
        #expect(users.count == 2)
        #expect(users[1].contains("だ・である"))
        #expect(users[1].contains("applicable は true のまま"))
        #expect(users[1].contains("調味料と冷凍食品の製造販売。"))
    }

    @Test func repairsEmptyApplicableOverviewUsingSource() async throws {
        let source = "当社は自動車の製造販売を行う。"
        let fixed = "自動車の製造販売を手がける。"
        let client = try ScriptedChat(replies: [
            reply(overview: ""),
            reply(overview: fixed),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input(source), client: client, model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.overview == fixed)
        #expect(draft.attempts == 2)
        let users = await client.users
        #expect(users.count == 2)
        #expect(users[1].contains(source))
        #expect(users[1].contains("applicable=true なのに overview が空")
            || users[1].contains("本文がない")
            || users[1].contains("overview が空"))
    }

    @Test func doesNotRetryApplicableFalseWhenInputHasBody() async throws {
        let source = """
            当社グループは総合エレクトロニクスメーカーとして開発・生産・販売・サービスを展開する。\
            製品の範囲は電気機械器具のほとんどすべてにわたっており、コネクト、エナジー、インダストリー、\
            スマートライフの報告セグメントから構成される。
            """
        #expect(source.count >= companyOverviewInputThinChars)
        let client = try ScriptedChat(replies: [
            reply(overview: "", applicable: false),
            reply(overview: "呼ばれてはいけない文。"),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input(source), client: client, model: companyOverviewDefaultModel)
        #expect(!draft.ok)
        #expect(!draft.applicable)
        #expect(draft.attempts == 1)
        #expect(await client.callCount() == 1)
    }

    @Test func thinApplicableFalseIsNotConfirmedNotApplicable() async throws {
        let source = "事業の内容の記載は省略する。"
        #expect(source.count < companyOverviewInputThinChars)
        #expect(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let client = try ScriptedChat(replies: [
            reply(overview: "", applicable: false),
            reply(overview: "", applicable: false),
            reply(overview: "", applicable: false),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input(source), client: client, model: companyOverviewDefaultModel)
        #expect(!draft.ok)
        #expect(!draft.applicable)
        #expect(draft.okDetail.contains("applicable=false"))
        #expect(await client.callCount() == 3)
    }

    @Test func systemPromptTreatsSegmentNamesAsEnough() {
        #expect(CompanyOverviewGenerator.systemPrompt.contains("製品名は必須ではない"))
        #expect(CompanyOverviewGenerator.systemPrompt.contains("セグメント名"))
        #expect(CompanyOverviewGenerator.systemPrompt.contains("報告セグメントの概要"))
        #expect(CompanyOverviewGenerator.systemPrompt.contains("「報告セグメント」という語も出さない"))
    }

    @Test func repairsReportableSegmentWrapper() async throws {
        let wrapped =
            "半導体・電子材料、モビリティ、イノベーション材料、ケミカル、クラサスケミカルの5つの報告セグメントで事業を行う。"
        let fixed = "半導体・電子材料、モビリティ、イノベーション材料、ケミカル、クラサスケミカルを手がける。"
        let client = try ScriptedChat(replies: [
            reply(overview: wrapped),
            reply(overview: fixed),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("半導体・電子材料とモビリティ等を報告セグメントとしている。"), client: client,
            model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.overview == fixed)
        #expect(draft.attempts == 2)
        let users = await client.users
        #expect(users[1].contains("報告セグメント"))
        #expect(users[1].contains("枠は書かない"))
    }

    @Test func userPromptUsesSegmentOverviewHeadingWhenFallback() async throws {
        let overview = "トイホビー、デジタル、映像音楽、アミューズメントの企画・製造・販売を手がける。"
        let client = try ScriptedChat(replies: [reply(overview: overview)])
        let draft = await CompanyOverviewGenerator.generate(
            input: CompanyOverviewInput(
                code: "7832", name: "バンダイナムコホールディングス", sector: "その他製品",
                docID: "S100YBXE",
                sourceText: "トイホビー事業、デジタル事業を報告セグメントとしている。",
                inputKey: companyOverviewSegmentOverviewInputKey,
                sectionTitle: companyOverviewSegmentOverviewSectionTitle),
            client: client, model: companyOverviewDefaultModel)
        #expect(draft.ok)
        let users = await client.users
        #expect(users[0].contains(companyOverviewSegmentOverviewInputKey))
        #expect(users[0].contains(companyOverviewSegmentOverviewSectionTitle))
        #expect(!users[0].contains("企業の概況 / \(companyOverviewSectionTitle)"))
    }

    @Test func repairApplicableFalseKeepsPrevious() async throws {
        let good =
            "調味料、栄養・加工食品、冷凍食品、医薬用・食品用アミノ酸、バイオファーマサービスなどを国内海外で提供。"
        let client = try ScriptedChat(replies: [
            reply(overview: good + "です"),
            reply(overview: "", applicable: false),
            reply(overview: "", applicable: false),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("調味料の製造販売。"), client: client, model: companyOverviewDefaultModel)
        #expect(draft.applicable)
        #expect(draft.overview.contains("調味料"))
        #expect(await client.callCount() == 3)
        #expect(draft.attempts == 3)
    }

    @Test func acceptsPunctuatedShortReplyWithoutPadding() async throws {
        let short = "デジタルソフトウェア・アドオンコンテンツの制作・販売、家庭用ゲーム機、音楽制作を手がける。"
        #expect(short.count == 45)
        let client = try ScriptedChat(replies: [reply(overview: short)])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("ゲーム、音楽の制作販売。"), client: client,
            model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.overview == short)
        #expect(draft.charCount == 45)
        #expect(draft.attempts == 1)
        #expect(await client.callCount() == 1)
    }

    @Test func addsSentenceStopWithoutPaddingForLength() async throws {
        let short = "ゲーム機と音楽制作を手がける"
        #expect(short.count < companyOverviewMinChars)
        let client = try ScriptedChat(replies: [reply(overview: short)])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("ゲームと音楽。"), client: client, model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.clipped)
        #expect(draft.overview == short + "。")
        #expect(draft.charCount == short.count + 1)
        #expect(draft.attempts == 1)
        #expect(await client.callCount() == 1)
    }

    @Test func clipsOverflowAtCommaWithoutRepair() async throws {
        let overflow =
            "IoTプラットフォーム「SORACOM」を提供し、IoTデバイス、IoT SIM、通信回線、データ保存・可視化アプリケーション、ネットワークサービスなどを手がける。"
        #expect(overflow.count == 82)
        let client = try ScriptedChat(replies: [reply(overview: overflow)])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("IoT通信プラットフォームの提供。"), client: client,
            model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.clipped)
        #expect(
            draft.overview
                == "IoTプラットフォーム「SORACOM」を提供し、IoTデバイス、IoT SIM、通信回線、データ保存・可視化アプリケーション。")
        #expect(draft.attempts == 1)
        #expect(await client.callCount() == 1)
    }

    @Test func doesNotSalvageConnectiveStemWithStop() async throws {
        let stem = "自動車を製造し"
        let fixed = "自動車の製造販売を手がける。"
        let client = try ScriptedChat(replies: [
            reply(overview: stem),
            reply(overview: fixed),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("自動車の製造販売。"), client: client, model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.overview == fixed)
        #expect(!draft.clipped)
        #expect(draft.attempts == 2)
        #expect(await client.callCount() == 2)
    }

    @Test func overflowConnectiveCommaGoesToRepair() async throws {
        let overflow = "自動車を製造し、" + String(repeating: "販", count: 80) + "する。"
        let fixed = "自動車の製造販売を手がける。"
        let client = try ScriptedChat(replies: [
            reply(overview: overflow),
            reply(overview: fixed),
        ])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("自動車の製造販売。"), client: client, model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(draft.overview == fixed)
        #expect(!draft.clipped)
        #expect(await client.callCount() == 2)
    }

    @Test func doesNotDoublePunctuationOnShortReply() async throws {
        let short = String(repeating: "あ", count: 48) + "。"
        #expect(short.count == 49)
        let client = try ScriptedChat(replies: [reply(overview: short)])
        let draft = await CompanyOverviewGenerator.generate(
            input: input("自動車の製造販売。"), client: client, model: companyOverviewDefaultModel)
        #expect(draft.ok)
        #expect(!draft.clipped)
        #expect(draft.overview == short)
        #expect(!draft.overview.hasSuffix("。。"))
        #expect(draft.attempts == 1)
        #expect(await client.callCount() == 1)
    }
}
