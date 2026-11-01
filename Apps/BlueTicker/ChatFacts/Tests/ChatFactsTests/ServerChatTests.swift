import Foundation
import Testing

@testable import ChatFacts

@Suite struct ServerChatTests {
    @Test func parsesServerSentEventLines() {
        #expect(ServerChatEvent.parse(line: #"data: {"text":"為替","type":"delta"}"#) == .delta("為替"))
        #expect(
            ServerChatEvent.parse(line: #"data: {"label":"有報の「事業等のリスク」","name":"get_filing_section","type":"tool"}"#)
                == .tool(label: "有報の「事業等のリスク」"))
        #expect(ServerChatEvent.parse(line: #"data: {"type":"done","usage":{"prompt_tokens":1}}"#) == .done)
        #expect(ServerChatEvent.parse(line: #"data: {"message":"失敗","type":"error"}"#) == .failure("失敗"))
        #expect(ServerChatEvent.parse(line: "") == nil)
        #expect(ServerChatEvent.parse(line: ": comment") == nil)
        #expect(ServerChatEvent.parse(line: "data: not json") == nil)
        #expect(ServerChatEvent.parse(line: #"data: {"type":"unknown"}"#) == nil)
    }

    @Test func requestBodyKeepsRecentExchangesOldestFirst() throws {
        let exchanges = (1...5).map { ChatContext.Exchange(question: "質問\($0)", answer: "回答\($0)") }
            + [ChatContext.Exchange(question: "失敗した質問", answer: " ")]
        let data = ServerChatRequest.body(code: "7203", exchanges: exchanges, question: "今回")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["code"] as? String == "7203")
        let messages = try #require(object["messages"] as? [[String: String]])
        // 直近 3 件（うち 1 件は回答が空なので落とす）＋今回の質問。
        #expect(messages.map { $0["content"] ?? "" } == ["質問4", "回答4", "質問5", "回答5", "今回"])
        #expect(messages.map { $0["role"] ?? "" } == ["user", "assistant", "user", "assistant", "user"])
    }

    @Test func requestBodyClipsLongText() throws {
        let long = String(repeating: "あ", count: 2_500)
        let data = ServerChatRequest.body(code: "7203", exchanges: [], question: long)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages.first?["content"]?.count == ServerChatRequest.maxCharacters)
    }

    @Test func routesReportQuestionsToServer() {
        #expect(ChatRouting.needsReport("利益率が下がった理由は？"))
        #expect(ChatRouting.needsReport("主なリスクを教えて"))
        #expect(ChatRouting.needsReport("セグメント別の売上は？"))
        #expect(ChatRouting.needsReport("m&aの方針は"))
        #expect(!ChatRouting.needsReport("売上高はいくら？"))
        #expect(!ChatRouting.needsReport("ROEは？"))
        #expect(!ChatRouting.needsReport("従業員数は増えた？"))
    }

    @Test func refusedEventIsParsed() {
        #expect(ServerChatEvent.parse(line: #"data: {"message":"お答えできません","type":"refused"}"#) == .refused("お答えできません"))
    }

    @Test func guardCatchesPersonalInformation() {
        for question in [
            "連絡は taro@example.com までお願いします",
            "電話は 090-1234-5678 です",
            "０９０１２３４５６７８に電話して",
            "03-1234-5678",
            "カードは 4111 1111 1111 1111",
            "マイナンバーは123456789012です",
            "口座番号 1234567 の残高で買える？",
            "〒100-0001 に住んでいます",
        ] {
            #expect(ChatGuard.check(question) == .personalInformation, "\(question)")
        }
    }

    @Test func guardCatchesInvestmentAdvice() {
        #expect(ChatGuard.check("この会社の株は今買うべき？") == .investmentAdvice)
        #expect(ChatGuard.check("目標株価を教えて") == .investmentAdvice)
        #expect(ChatGuard.check("売り時はいつ？") == .investmentAdvice)
    }

    @Test func guardLetsOrdinaryQuestionsThrough() {
        for question in [
            "26年3月期の売上高は？",
            "2025-2026 の営業利益の変化は？",
            "売上高 1,234億円 の内訳は？",
            "ROEは8.3%から上がった？",
            "主なリスクは？",
        ] {
            #expect(ChatGuard.check(question) == nil, "\(question)")
        }
    }
}
