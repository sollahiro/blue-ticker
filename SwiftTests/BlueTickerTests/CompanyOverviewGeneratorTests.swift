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
}
