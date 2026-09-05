// 銘柄 Overview（短い会社説明。50〜80字は目安で、下限は不合格にしない）。
// Filing 公開 `texts` には載せない。生成・検証は ingest 時。serving / 別 EP / iOS 要約は未配線。

import Foundation

/// Overview 生成キャッシュ（将来の別格納）。serving / healthz にはまだ載せない。
public let companyOverviewCacheVersion = "overview-v1"

public let companyOverviewInputKey = "description_of_business"
public let companyOverviewSectionTitle = "事業の内容"
/// ヘッダ用の目安下限。情報量が少なければこれより短くてよい（不合格にしない）。
public let companyOverviewMinChars = 50
/// ヘッダ用の目安上限。超えたら句点で切り、切れなければ不合格。
public let companyOverviewMaxChars = 80
public let companyOverviewMaxInputChars = 6000
public let companyOverviewInputThinChars = 80
public let companyOverviewMaxAttempts = 3
public let companyOverviewDefaultModel = "google/gemini-2.5-flash"
public let companyOverviewJSONSchemaName = "company_overview"
/// Overview 用キー（機能名入り）。
public let companyOverviewAPIKeyEnv = "OPENROUTER_OVERVIEW_API_KEY"
public let companyOverviewModelEnv = "OPENROUTER_OVERVIEW_MODEL"
public let companyOverviewBaseURLEnv = "OPENROUTER_OVERVIEW_BASE_URL"

/// LLM 呼び出し前の入力。空ならモデルを呼ばない。
public struct CompanyOverviewInput: Sendable, Equatable {
    public var code: String
    public var name: String
    public var sector: String
    public var docID: String
    public var sourceText: String

    public init(code: String, name: String, sector: String, docID: String, sourceText: String) {
        self.code = code
        self.name = name
        self.sector = sector
        self.docID = docID
        self.sourceText = sourceText
    }
}

/// 生成結果。公開 REST の形ではない。
public struct CompanyOverviewDraft: Sendable, Equatable {
    public var applicable: Bool
    public var overview: String
    public var charCount: Int
    public var reason: String
    public var ok: Bool
    public var okDetail: String
    public var clipped: Bool
    public var attempts: Int
    public var model: String
    public var inputCharsTotal: Int
    public var inputCharsUsed: Int
    public var inputThin: Bool

    public init(
        applicable: Bool, overview: String, charCount: Int, reason: String, ok: Bool,
        okDetail: String, clipped: Bool, attempts: Int, model: String, inputCharsTotal: Int,
        inputCharsUsed: Int, inputThin: Bool
    ) {
        self.applicable = applicable
        self.overview = overview
        self.charCount = charCount
        self.reason = reason
        self.ok = ok
        self.okDetail = okDetail
        self.clipped = clipped
        self.attempts = attempts
        self.model = model
        self.inputCharsTotal = inputCharsTotal
        self.inputCharsUsed = inputCharsUsed
        self.inputThin = inputThin
    }
}

enum CompanyOverviewEvaluation: Equatable {
    case ok
    case invalid(String)
}

enum CompanyOverviewRules {
    static func evaluate(applicable: Bool, overview: String) -> CompanyOverviewEvaluation {
        let text = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicable {
            return text.isEmpty ? .ok : .invalid("applicable=false なのに overview が空でない")
        }
        if text.isEmpty {
            return .invalid("applicable=true なのに overview が空")
        }
        let n = text.count
        if n > companyOverviewMaxChars {
            return .invalid("字数 \(n) が目安上限 \(companyOverviewMaxChars) を超えている")
        }
        if matches(Self.amountRegex, in: text) {
            return .invalid("金額・件数・比率らしい数字が入っている")
        }
        if matches(Self.buyRegex, in: text) {
            return .invalid("買い推奨が混ざっている")
        }
        if matches(Self.desumasuRegex, in: text) {
            return .invalid("ですます調になっている")
        }
        if matches(Self.yearRegex, in: text) {
            return .invalid("年度が入っている")
        }
        if matches(Self.goalRegex, in: text) {
            return .invalid("目標・中計が入っている")
        }
        if text.contains("株式会社") {
            return .invalid("株式会社が残っている")
        }
        guard endsWithSentenceStop(text) else {
            return .invalid("言い切りの句点がない")
        }
        let sentences = sentenceCount(text)
        if sentences > 2 {
            return .invalid("文が\(sentences)つある")
        }
        return .ok
    }

    /// 80字超を窓内の最も右の句点で切る。途中切れは捨てる。短い完成文は残してよい。
    static func clip(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= companyOverviewMaxChars { return trimmed }
        let window = String(trimmed.prefix(companyOverviewMaxChars))
        var idx = window.endIndex
        while idx > window.startIndex {
            idx = window.index(before: idx)
            guard isSentenceStop(window[idx]) else { continue }
            let clipped = String(window[...idx])
            if case .ok = evaluate(applicable: true, overview: clipped) {
                return clipped
            }
        }
        return nil
    }

    static func endsWithSentenceStop(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return isSentenceStop(last)
    }

    private static func isSentenceStop(_ ch: Character) -> Bool {
        "。！？".contains(ch)
    }

    private static func sentenceCount(_ text: String) -> Int {
        var count = 0
        var current = ""
        for ch in text {
            if isSentenceStop(ch) {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    count += 1
                }
                current = ""
            } else {
                current.append(ch)
            }
        }
        return count
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let amountRegex = try! NSRegularExpression(
        pattern:
            #"(?:\d[\d,\.]*)\s*(?:円|億円|兆円|百万円|千万円|%|％|倍|人|件|社)|(?:売上|営業利益|純利益|時価総額)\s*\d"#
    )
    private static let buyRegex = try! NSRegularExpression(
        pattern: #"買い推奨|買い判断|割安|投資せよ|おすすめ銘柄|投資判断"#)
    private static let desumasuRegex = try! NSRegularExpression(
        pattern: #"です|ます|でした|ました|ません|でしょう|ください"#)
    private static let yearRegex = try! NSRegularExpression(pattern: #"(?:19|20)\d{2}\s*年|令和|平成|年度"#)
    private static let goalRegex = try! NSRegularExpression(pattern: #"中計|目標を|目指し"#)
}
