import Foundation

/// サーバーのチャット（`POST /v1/chat`）とのやりとり。通信そのものはアプリ側（`APIClient`）が持ち、
/// ここは本文の組み立て・SSE の 1 行の解釈・振り分けの判定だけを置く（Linux で `swift test` できる）。

/// サーバーから届くイベント。
enum ServerChatEvent: Equatable, Sendable {
    /// 回答本文の続き。
    case delta(String)
    /// 有報などを読み始めた。`label` は「有報の「事業等のリスク」」のような表示名。
    case tool(label: String)
    case done
    case failure(String)

    /// SSE の 1 行（`data: {...}`）を読む。関係ない行は nil。
    static func parse(line: String) -> ServerChatEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "delta":
            guard let text = object["text"] as? String else { return nil }
            return .delta(text)
        case "tool":
            return .tool(label: object["label"] as? String ?? "資料")
        case "done":
            return .done
        case "error":
            return .failure(object["message"] as? String ?? "回答を取得できませんでした。")
        default:
            return nil
        }
    }
}

enum ServerChatRequest {
    /// 送る過去のやりとりの数（新しい順）。サーバーは 12 件・各 2,000 字まで受け付ける。
    static let maxExchanges = 3
    static let maxCharacters = 2_000

    /// `{"code":..., "messages":[...]}`。古い順に並べ、最後に今回の質問を置く。
    static func body(code: String, exchanges: [ChatContext.Exchange], question: String) -> Data {
        var messages: [[String: String]] = []
        for exchange in exchanges.suffix(maxExchanges) {
            let answer = exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { continue }
            messages.append(["role": "user", "content": String(exchange.question.prefix(maxCharacters))])
            messages.append(["role": "assistant", "content": String(answer.prefix(maxCharacters))])
        }
        messages.append(["role": "user", "content": String(question.prefix(maxCharacters))])
        let object: [String: Any] = ["code": code, "messages": messages]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// 質問をどちらで答えるか。端末内のモデルは手元の数字の表で足りる質問だけを受け持ち、
/// 有報の文章が要る質問はサーバーへ送る。
enum ChatRouting {
    enum Destination: Equatable, Sendable {
        case device
        case server
    }

    /// 有報の文章（理由・方針・リスク・内訳など）が要ると判断できる語。含めばモデルに聞かずにサーバーへ送る。
    static let reportKeywords = [
        "なぜ", "理由", "要因", "背景", "原因",
        "リスク", "課題", "戦略", "方針", "計画", "見通し", "今後", "将来",
        "事業", "セグメント", "部門", "製品", "サービス", "地域", "海外", "国内", "顧客", "競合", "シェア",
        "研究", "開発", "設備", "投資", "工場", "M&A", "買収",
        "人材", "賃金", "為替", "原材料", "価格",
        "有報", "有価証券報告書", "経営者", "強み", "弱み",
    ]

    static func needsReport(_ question: String) -> Bool {
        let folded = question.lowercased()
        return reportKeywords.contains { folded.contains($0.lowercased()) }
    }
}
