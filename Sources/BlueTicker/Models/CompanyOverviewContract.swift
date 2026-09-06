// 銘柄 Overview（短い会社説明。50〜80字は目安で、下限は不合格にしない。合格上限は90字）。
// Filing 公開 `texts` には載せない。生成・検証は ingest 時。格納は `company_overviews`
// （会社1社=1行。由来の有報は doc_id 列）。ingest stage は `overviews`。
// 公開 REST は `GET /v1/companies/{code}/overview`（MCP には出さない。iOS は Summary 上部）。

import Crypto
import Foundation

/// Overview 格納キャッシュ（`company_overviews.cache_version`）。blueTickerVersion 非連動。
/// プロンプト・検証規則・本 payload の意味を変えたときだけバンプする。
/// ingest は LLM 成功行をバンプだけでは再生成しない（最新有報の doc_id 変更と needs_review）。
/// `not_applicable` は決定論行なので版ずれで再実行する。
public let companyOverviewCacheVersion = "overview-v3"

/// overview read（REST）が 200 を返す最低世代番号（`overview-vN` の N）。
/// **明示指定**であり、「現行から N つ前」の機械オフセットではない。人手で上げる。
/// ingest の stale 判定・書き込みは常に `companyOverviewCacheVersion`。床未満の行は 404。
/// 床の引き上げは、該当旧版の stale 消化が終わってから行う。
/// 不変条件: `companyOverviewMinServableVersion` ≤ 現行 `overview-vN` の N。
public let companyOverviewMinServableVersion = 1

/// `overview-vN` 形式から世代番号 N を取り出す。パース不能なら nil（非 servable 扱い）。
public func companyOverviewCacheVersionNumber(_ version: String) -> Int? {
    guard version.hasPrefix("overview-v") else { return nil }
    let suffix = version.dropFirst("overview-v".count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
    return n
}

/// 格納行の `cache_version` が read 床以上か。文字列辞書順比較は使わない。
public func isServableCompanyOverviewCacheVersion(_ version: String) -> Bool {
    guard let n = companyOverviewCacheVersionNumber(version) else { return false }
    return n >= companyOverviewMinServableVersion
}

/// 公開 REST の `schema_version`。応答形を破壊的に変えたときのみ +1。
public let companyOverviewServeSchemaVersion = 1
/// LLM 生成行。入力が読めてモデルを呼んだとき。
public let companyOverviewSourceLLM = "llm"
/// 入力が空、または事業内容が全く読めず applicable=false のとき。
public let companyOverviewSourceNotApplicable = "not_applicable"

public let companyOverviewInputKey = "description_of_business"
public let companyOverviewSectionTitle = "事業の内容"
/// 事業の内容が系統図だけで読めないときのフォールバック入力。
public let companyOverviewSegmentOverviewInputKey = "reportable_segments_overview"
public let companyOverviewSegmentOverviewSectionTitle = "報告セグメントの概要"
/// ヘッダ用の目安下限。情報量が少なければこれより短くてよい（不合格にしない）。
public let companyOverviewMinChars = 50
/// 合格上限。目安は 50〜80 字。超えたら句点、なければ読点の直前で切る。切れなければ不合格。
public let companyOverviewMaxChars = 90
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
    public var inputKey: String
    public var sectionTitle: String

    public init(
        code: String, name: String, sector: String, docID: String, sourceText: String,
        inputKey: String = companyOverviewInputKey,
        sectionTitle: String = companyOverviewSectionTitle
    ) {
        self.code = code
        self.name = name
        self.sector = sector
        self.docID = docID
        self.sourceText = sourceText
        self.inputKey = inputKey
        self.sectionTitle = sectionTitle
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

/// `company_overviews.payload`。生成結果の格納契約（公開 REST の形ではない）。
public struct CompanyOverviewPayload: Codable, Sendable, Equatable {
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

    private enum CodingKeys: String, CodingKey {
        case applicable
        case overview
        case charCount = "char_count"
        case reason
        case ok
        case okDetail = "ok_detail"
        case clipped
        case attempts
        case model
        case inputCharsTotal = "input_chars_total"
        case inputCharsUsed = "input_chars_used"
        case inputThin = "input_thin"
    }

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

    public init(draft: CompanyOverviewDraft) {
        self.init(
            applicable: draft.applicable, overview: draft.overview, charCount: draft.charCount,
            reason: draft.reason, ok: draft.ok, okDetail: draft.okDetail, clipped: draft.clipped,
            attempts: draft.attempts, model: draft.model, inputCharsTotal: draft.inputCharsTotal,
            inputCharsUsed: draft.inputCharsUsed, inputThin: draft.inputThin)
    }

    /// `ok=false` を再処理キューへ載せるための複製元。JSONB を掘らない。
    public var needsReview: Bool { !ok }

    /// 入力空など「対象外で確定」したときだけ `not_applicable`。生成失敗（`ok=false`）は
    /// `applicable` が false でも `llm` のまま残し、再処理対象にする。
    public var source: String {
        !applicable && ok ? companyOverviewSourceNotApplicable : companyOverviewSourceLLM
    }

    /// `source == not_applicable` の行だけ理由をトップレベル列へ出す。
    public var notApplicableReason: String? { !applicable && ok ? reason : nil }
}

/// 生入力（事業の内容本文）のみのハッシュ。プロンプト・モデルは含めない。
public func companyOverviewContentHash(_ sourceText: String) -> String {
    SHA256.hash(data: Data(sourceText.utf8)).map { String(format: "%02x", $0) }.joined()
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
        guard endsWithSentenceStop(text) else {
            return .invalid("言い切りの句点がない")
        }
        let sentences = sentenceBodies(text)
        if sentences.isEmpty || sentences.contains(where: { !hasSubstantiveBody($0) }) {
            return .invalid("本文がない")
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
        if text.contains("報告セグメント") {
            return .invalid("報告セグメントという枠でまとめている")
        }
        if matches(Self.segmentCountRegex, in: text) {
            return .invalid("セグメントの数え上げでまとめている")
        }
        if text.contains("株式会社") {
            return .invalid("株式会社が残っている")
        }
        if sentences.count > 2 {
            return .invalid("文が\(sentences.count)つある")
        }
        if sentences.contains(where: { matches(Self.incompleteEndingRegex, in: $0) }) {
            return .invalid("言い切りになっていない")
        }
        return .ok
    }

    /// 上限超を窓内の最も右の句点で切る。無ければ読点の直前で切って句点を付ける。
    /// 途中切れは捨てる。短い完成文は残してよい。
    static func clip(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= companyOverviewMaxChars { return trimmed }
        let window = String(trimmed.prefix(companyOverviewMaxChars))
        var idx = window.endIndex
        while idx > window.startIndex {
            idx = window.index(before: idx)
            guard isBoundarySentenceStop(window, at: idx) else { continue }
            let clipped = String(window[...idx])
            if case .ok = evaluate(applicable: true, overview: clipped) {
                return clipped
            }
        }
        idx = window.endIndex
        while idx > window.startIndex {
            idx = window.index(before: idx)
            guard window[idx] == "、" else { continue }
            if idx > window.startIndex {
                let prev = window.index(before: idx)
                if window[prev] == "！" || window[prev] == "？" { continue }
            }
            var prefix = String(window[..<idx])
            while let stripped = strippingTrailingConnective(prefix), !stripped.isEmpty {
                prefix = stripped
            }
            let candidate = prefix + "。"
            if candidate.count > companyOverviewMaxChars { continue }
            if case .ok = evaluate(applicable: true, overview: candidate) {
                return candidate
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

    /// 「ロリポップ！、」の感嘆符は文末ではない。
    private static func isBoundarySentenceStop(_ text: String, at idx: String.Index) -> Bool {
        let ch = text[idx]
        guard isSentenceStop(ch) else { return false }
        let next = text.index(after: idx)
        if (ch == "！" || ch == "？"), next < text.endIndex, text[next] == "、" {
            return false
        }
        return true
    }

    /// 句読点・空白だけは本文と見ない。漢字・かな・英数字があれば通す。
    private static func hasSubstantiveBody(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }

    /// 句点で区切った文の本体。空白だけの区間は飛ばす。句読点だけの区間は残す。
    /// 「ロリポップ！、」のように感嘆符の直後が読点なら文を切らない。
    private static func sentenceBodies(_ text: String) -> [String] {
        var bodies: [String] = []
        var current = ""
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            let next = text.index(after: idx)
            if isBoundarySentenceStop(text, at: idx) {
                let body = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    bodies.append(body)
                }
                current = ""
            } else {
                current.append(ch)
            }
            idx = next
        }
        return bodies
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 読点クリップ後の「と。」「し。」を言い切りにしない。
    private static func strippingTrailingConnective(_ text: String) -> String? {
        let suffixes = ["と", "や"]
        for suffix in suffixes where text.hasSuffix(suffix) {
            return String(text.dropLast(suffix.count))
        }
        return nil
    }

    private static let amountRegex = try! NSRegularExpression(
        pattern:
            #"(?:\d[\d,\.]*)\s*(?:億円|兆円|百万円|千万円|円(?!ショップ|均一ショップ)|%|％|倍|人|件|社)|(?:売上|営業利益|純利益|時価総額)\s*\d"#
    )
    private static let buyRegex = try! NSRegularExpression(
        pattern: #"買い推奨|買い判断|割安|投資せよ|おすすめ銘柄|投資判断"#)
    /// 文末のですますだけ見る。直後の句点が無い「でしょうゆ」は対象外。
    private static let desumasuRegex = try! NSRegularExpression(
        pattern: #"(?:でした|ました|ません|でしょう|ください|です|ます)[。！？]"#)
    private static let yearRegex = try! NSRegularExpression(pattern: #"(?:19|20)\d{2}\s*年|令和|平成|年度"#)
    private static let goalRegex = try! NSRegularExpression(pattern: #"中計|目標を|目指し"#)
    /// 「5つのセグメントで事業を行う」のような開示枠。報告セグメントは contains で別途見る。
    private static let segmentCountRegex = try! NSRegularExpression(
        pattern: #"(?:[0-9０-９]+|[一二三四五六七八九十]+)[つ個]の(?:事業)?セグメント|セグメントから構成"#)
    /// 連用中止・助詞で終わった文。「製造し。」「製造して。」を言い切りとしない。
    private static let incompleteEndingRegex = try! NSRegularExpression(
        pattern: #"(?:しつつ|ながら|かつ|および|ならびに|または|し|て|で|を|に|が|は|と|の|も|ば)$"#)
}

/// 公開 REST の Overview 応答。ingest 内部フィールド（model / attempts 等）は出さない。
public func companyOverviewServeJSON(code: String, overview: String, docID: String) -> [String: Any] {
    [
        "schema_version": companyOverviewServeSchemaVersion,
        "code": code,
        "overview": overview,
        "doc_id": docID,
    ]
}
