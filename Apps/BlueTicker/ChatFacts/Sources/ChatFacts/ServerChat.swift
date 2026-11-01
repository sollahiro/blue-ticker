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
    /// サーバーの事前チェックで断られた（売買の判断・個人情報）。
    case refused(String)

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
        case "refused":
            return .refused(object["message"] as? String ?? "この質問にはお答えできません。")
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
/// 有報の文章が要る質問はサーバーへ送る。ここは語での一次判定。語で決まらない質問は
/// アプリ側で端末内のモデルに判定させる（`ChatQuestionRoute`）。
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

/// 送る前の事前チェック。売買の判断・株価の予想を求める質問と、個人情報を含む質問は答えない。
/// 個人情報は端末の外へ出さないよう、ここで見つかればサーバーへも送らない。
/// 語や書式で拾えないものは、端末内のモデル（アプリ側）とサーバーの事前チェックが受け持つ。
enum ChatGuard {
    enum Reason: Equatable, Sendable {
        case investmentAdvice
        case personalInformation

        var message: String {
            switch self {
            case .investmentAdvice:
                return "売買の判断や株価の見通しにはお答えできません。業績や事業の内容についての質問をどうぞ。"
            case .personalInformation:
                return "個人を特定できる情報が含まれているようなので、送信しませんでした。その部分を消してから質問してください。"
            }
        }
    }

    static func check(_ question: String) -> Reason? {
        if containsPersonalInformation(question) { return .personalInformation }
        if asksInvestmentAdvice(question) { return .investmentAdvice }
        return nil
    }

    static let adviceKeywords = [
        "買うべき", "売るべき", "買い時", "売り時", "買った方が", "売った方が", "買ったほうが", "売ったほうが",
        "買いですか", "売りですか", "今が買い", "今買う", "投資すべき", "投資した方が", "投資したほうが",
        "儲かる", "株価は上がる", "株価は下がる", "株価が上がる", "株価が下がる", "株価予想", "株価の予想",
        "目標株価", "おすすめの銘柄", "オススメの銘柄", "推奨銘柄", "損切り", "利確", "ナンピン",
    ]

    static func asksInvestmentAdvice(_ question: String) -> Bool {
        adviceKeywords.contains { question.contains($0) }
    }

    /// 書式で分かる個人情報（メールアドレス・電話番号・カード番号・マイナンバー・口座番号・郵便番号）。
    private static let personalPatterns: [NSRegularExpression] = [
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"(?<!\d)0\d{1,4}-\d{1,4}-\d{3,4}(?!\d)"#,
        #"(?<!\d)0[5789]0\d{8}(?!\d)"#,
        #"(?<!\d)\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}(?!\d)"#,
        #"(?<!\d)\d{4}[ -]?\d{4}[ -]?\d{4}(?!\d)"#,
        #"口座(番号)?\D{0,6}\d{7}(?!\d)"#,
        #"〒\s?\d{3}-?\d{4}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func containsPersonalInformation(_ question: String) -> Bool {
        let text = halfwidth(question)
        let range = NSRange(text.startIndex..., in: text)
        return personalPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// 全角英数・記号を半角に、各種ダッシュ・長音を "-" に寄せる（書式の判定用）。
    static func halfwidth(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            case 0x3000:
                out.append(" ")
            case 0x2010...0x2015, 0x2212, 0x30FC, 0xFF70:
                out.append("-")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
