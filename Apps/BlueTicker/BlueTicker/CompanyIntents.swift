import AppIntents
import Foundation
import NaturalLanguage
import SwiftData
import UniformTypeIdentifiers
import Vision
#if canImport(VisualIntelligence)
import VisualIntelligence
#endif

/// Siri / ショートカットから呼ぶ操作。銘柄の候補は出さず、入力した文字（社名または証券コード）を
/// そのまま `GET /v1/companies?q=` で検索して使う。
/// App Shortcuts のフレーズには文字列パラメータを入れられないので、フレーズは「有報LABで会社を調べる」のように
/// 固定にし、会社名は Siri の聞き返し（またはショートカットの入力欄・変数）で受け取る。
private struct CompanyIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum CompanyLookup {
    /// 全角数字を半角にそろえ、前後の空白を除く（「７２０３」→「7203」）。
    static func normalized(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if (0xFF10...0xFF19).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) {
                return Character(ascii)
            }
            return Character(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func search(_ raw: String) async throws -> [CompanyHit] {
        let query = normalized(raw)
        guard !query.isEmpty else {
            throw CompanyIntentError(message: "会社名か証券コードを入力してください。")
        }
        let hits: [CompanyHit]
        do {
            hits = try await APIClient.shared.searchCompanies(query: query)
        } catch {
            throw CompanyIntentError(message: "「\(query)」を検索できませんでした。")
        }
        guard !hits.isEmpty else {
            throw CompanyIntentError(message: "「\(query)」に一致する会社が見つかりませんでした。")
        }
        return hits
    }

    /// 証券コードが完全一致する会社を優先し、なければ検索の先頭を使う。
    static func resolveHit(_ raw: String) async throws -> CompanyHit {
        let hits = try await search(raw)
        let code = normalized(raw).uppercased()
        return hits.first(where: { $0.code.uppercased() == code }) ?? hits[0]
    }

    static func resolve(_ raw: String) async throws -> (code: String, name: String) {
        let hit = try await resolveHit(raw)
        return (hit.code, Format.displayName(hit.name, fallback: hit.code))
    }
}

/// ニュース記事などの長い文章から、会社名の候補を拾う。
/// 証券コード（`(7203)` や `証券コード 7203`）、「株式会社〇〇」「〇〇ホールディングス」などの形、
/// 言語解析の組織名、漢字・カタカナの連なりの順に出し、あとで有報LABの検索に照らして絞る。
enum CompanyTextExtractor {
    static let maxCandidates = 8

    static func candidates(in text: String) -> [String] {
        var result: [String] = []
        func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, value.count <= 30, !result.contains(value) else { return }
            result.append(value)
        }
        let body = CompanyLookup.normalized(text)
        let word = "[\\p{Han}\\p{Katakana}ーA-Za-z0-9&＆]"
        let patterns = [
            "[（(]\\s*([0-9]{3}[0-9A-Z])\\s*[)）]",
            "(?:証券コード|コード)[:：\\s]*([0-9]{3}[0-9A-Z])",
            "株式会社(\(word){1,15})",
            "(\(word){1,15}(?:ホールディングス|グループ))",
            "(\(word){1,15})株式会社",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..., in: body)
            for match in regex.matches(in: body, range: range) {
                // 取り出す範囲は、あれば括弧のグループ、なければ全体。
                let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                if let r = Range(group, in: body) { add(String(body[r])) }
            }
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = body
        tagger.enumerateTags(
            in: body.startIndex..<body.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag == .organizationName { add(String(body[range])) }
            return true
        }
        if let runs = try? NSRegularExpression(pattern: "[\\p{Han}\\p{Katakana}ー]{3,}") {
            let range = NSRange(body.startIndex..., in: body)
            let found = runs.matches(in: body, range: range).compactMap { Range($0.range, in: body).map { String(body[$0]) } }
            for run in found.sorted(by: { $0.count > $1.count }) { add(run) }
        }
        return Array(result.prefix(maxCandidates))
    }

    /// 候補を 1 つずつ検索し、会社名か証券コードが合うものだけ採る。最大 `limit` 社。
    static func resolve(_ candidates: [String], limit: Int = 5) async -> [CompanyHit] {
        var found: [CompanyHit] = []
        for candidate in candidates {
            guard found.count < limit else { break }
            guard let hits = try? await APIClient.shared.searchCompanies(query: candidate) else { continue }
            let key = candidate.uppercased()
            let hit = hits.first { hit in
                let name = Format.displayName(hit.name, fallback: hit.code)
                return hit.code.uppercased() == key || name.contains(candidate) || candidate.contains(name)
            }
            if let hit, !found.contains(where: { $0.code == hit.code }) { found.append(hit) }
        }
        return found
    }
}

/// 画面や画像から拾った会社。Visual Intelligence の結果と、結果画面を開く操作に使う。
struct CompanyEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "会社")
    static let defaultQuery = CompanyEntityQuery()

    let id: String
    let name: String
    let sector: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id) \(sector)")
    }

    init(hit: CompanyHit) {
        id = hit.code
        name = Format.displayName(hit.name, fallback: hit.code)
        sector = hit.sector ?? ""
    }
}

/// 銘柄の候補一覧は出さない（`suggestedEntities` は実装しない）。識別子（証券コード）から引くだけ。
struct CompanyEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CompanyEntity] {
        var result: [CompanyEntity] = []
        for code in identifiers {
            let hits = (try? await APIClient.shared.searchCompanies(query: code)) ?? []
            if let hit = hits.first(where: { $0.code == code }) {
                result.append(CompanyEntity(hit: hit))
            }
        }
        return result
    }
}

// 実機向けの SDK にだけ VisualIntelligence がある（CI のシミュレータ x86_64 には無い）。
#if canImport(VisualIntelligence)
/// カメラ（Visual Intelligence）や画面の画像に写った文字・ラベルから会社を探す。
struct CompanyVisualQuery: IntentValueQuery {
    func values(for input: SemanticContentDescriptor) async throws -> [CompanyEntity] {
        let text = input.labels.joined(separator: "\n")
        let hits = await CompanyTextExtractor.resolve(CompanyTextExtractor.candidates(in: text))
        return hits.map(CompanyEntity.init(hit:))
    }
}
#endif

/// Visual Intelligence の結果から、有報LABの結果画面を開く。
struct OpenCompanyEntityIntent: OpenIntent {
    static let title: LocalizedStringResource = "有報LABで会社を開く"
    static let openAppWhenRun = true

    @Parameter(title: "会社")
    var target: CompanyEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pending = CompanyRef(code: target.id, name: target.name, sector: target.sector)
        return .result()
    }
}

/// スクリーンショットや写真を受け取り、写っている文字を読み取って会社を探す。
/// 文字入力を求めずに、共有メニューやショートカットの画像をそのまま渡せる。
struct FindCompaniesInImageIntent: AppIntent {
    static let title: LocalizedStringResource = "画像から会社を探す"
    static let description = IntentDescription("スクリーンショットや写真に写った文字から会社名や証券コードを読み取り、有報LABに載っている会社を返します。")

    @Parameter(
        title: "画像", supportedContentTypes: [.image],
        requestValueDialog: "どの画像から会社を探しますか？",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$image)から会社を探す")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = image.data
        let recognized = try await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: data, options: [:]).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
        guard !recognized.isEmpty else {
            throw CompanyIntentError(message: "画像から文字を読み取れませんでした。")
        }
        let hits = await CompanyTextExtractor.resolve(CompanyTextExtractor.candidates(in: recognized))
        guard !hits.isEmpty else {
            throw CompanyIntentError(message: "有報LABに載っている会社を画像から見つけられませんでした。")
        }
        let text = hits.map { hit -> String in
            let name = Format.displayName(hit.name, fallback: hit.code)
            let sector = hit.sector.map { "（\($0)）" } ?? ""
            return "\(name) \(hit.code)\(sector)"
        }.joined(separator: "\n")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct FindCompaniesInTextIntent: AppIntent {
    static let title: LocalizedStringResource = "文章から会社を探す"
    static let description = IntentDescription("ニュース記事などの文章から会社名や証券コードを拾い、有報LABに載っている会社を返します。")

    @Parameter(
        title: "文章",
        requestValueDialog: "どの文章から会社を探しますか？",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$text)から会社を探す")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let candidates = CompanyTextExtractor.candidates(in: text)
        var hits = await CompanyTextExtractor.resolve(candidates)
        // 短い入力で何も拾えなかったときは、全体を会社名として検索する。
        let whole = CompanyLookup.normalized(text)
        if hits.isEmpty, whole.count <= 30, let found = try? await CompanyLookup.search(whole) {
            hits = Array(found.prefix(5))
        }
        guard !hits.isEmpty else {
            throw CompanyIntentError(message: "有報LABに載っている会社を文章から見つけられませんでした。")
        }
        let lines = hits.map { hit -> String in
            let name = Format.displayName(hit.name, fallback: hit.code)
            let sector = hit.sector.map { "（\($0)）" } ?? ""
            return "\(name) \(hit.code)\(sector)"
        }
        let text = lines.joined(separator: "\n")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Intent からアプリの画面へ行き先を渡す。`RootView` が見て、ホームタブに銘柄面を積む。
@MainActor @Observable
final class IntentRouter {
    static let shared = IntentRouter()
    var pending: CompanyRef?
}

struct SearchCompanyIntent: AppIntent {
    static let title: LocalizedStringResource = "会社名で検索する"
    static let description = IntentDescription("入力した会社名や証券コードに合う会社を、証券コードつきで返します。")

    @Parameter(title: "会社名または証券コード", requestValueDialog: "どの会社を探しますか？")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$query)を検索")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let hits = try await CompanyLookup.search(query)
        let text = hits.prefix(5).map { hit -> String in
            let name = Format.displayName(hit.name, fallback: hit.code)
            let sector = hit.sector.map { "（\($0)）" } ?? ""
            return "\(name) \(hit.code)\(sector)"
        }.joined(separator: "\n")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct CompanyOverviewIntent: AppIntent {
    static let title: LocalizedStringResource = "会社の概要を見る"
    static let description = IntentDescription("会社名や証券コードから、有報から作った会社の概要を返します。")

    @Parameter(title: "会社名または証券コード", requestValueDialog: "どの会社の概要を見ますか？")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$query)の概要")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let company = try await CompanyLookup.resolve(query)
        let response: CompanyOverviewResponse
        do {
            response = try await APIClient.shared.overview(code: company.code)
        } catch {
            throw CompanyIntentError(message: "\(company.name)の概要を取得できませんでした。")
        }
        let text = response.overview
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct CompanyFinancialsIntent: AppIntent {
    static let title: LocalizedStringResource = "会社の最新の業績を見る"
    static let description = IntentDescription("会社名や証券コードから、最新の決算期の売上高・営業利益・純利益・ROE を返します。")

    @Parameter(title: "会社名または証券コード", requestValueDialog: "どの会社の業績を見ますか？")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$query)の最新の業績")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let company = try await CompanyLookup.resolve(query)
        let response: FinancialsResponse
        do {
            response = try await APIClient.shared.financials(code: company.code)
        } catch {
            throw CompanyIntentError(message: "\(company.name)の業績を取得できませんでした。")
        }
        guard let year = Format.latestYear(response.years) else {
            throw CompanyIntentError(message: "\(company.name)の業績はまだ集計されていません。")
        }
        let currency = year.currency ?? response.currency
        let text = """
            \(company.name) \(Format.fyJapanese(year.fyEnd))
            売上高 \(Format.autoYen(year.sales, currency: currency))
            営業利益 \(Format.autoYen(year.operatingProfit, currency: currency))
            純利益 \(Format.autoYen(year.netProfit, currency: currency))
            ROE \(Format.percent(year.roe))
            """
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct OpenCompanyIntent: AppIntent {
    static let title: LocalizedStringResource = "会社の結果画面を開く"
    static let description = IntentDescription("会社名や証券コードから会社を探し、有報LABの分析結果の画面を開きます。")
    static let openAppWhenRun = true

    @Parameter(title: "会社名または証券コード", requestValueDialog: "どの会社の結果を開きますか？")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$query)の結果を開く")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hit = try await CompanyLookup.resolveHit(query)
        IntentRouter.shared.pending = CompanyRef(hit)
        let name = Format.displayName(hit.name, fallback: hit.code)
        return .result(dialog: IntentDialog(stringLiteral: "\(name)の結果を開きます。"))
    }
}

struct AddCompanyToWatchlistIntent: AppIntent {
    static let title: LocalizedStringResource = "会社をリストに追加する"
    static let description = IntentDescription("会社名や証券コードから会社を探し、有報LABのリストに追加します。")

    @Parameter(title: "会社名または証券コード", requestValueDialog: "どの会社をリストに追加しますか？")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$query)をリストに追加")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let hit = try await CompanyLookup.resolveHit(query)
        let name = Format.displayName(hit.name, fallback: hit.code)
        let context = BlueTickerApp.sharedContainer.mainContext
        let existing = (try? context.fetch(FetchDescriptor<WatchedCompany>())) ?? []
        let text: String
        if existing.contains(where: { $0.code == hit.code }) {
            text = "\(name)はすでにリストにあります。"
        } else {
            context.insert(
                WatchedCompany(
                    code: hit.code,
                    name: hit.name,
                    sector: hit.sector ?? "",
                    iconURL: hit.iconURL,
                    sortOrder: WatchedCompany.nextSortOrder(among: existing)
                )
            )
            do {
                try context.save()
            } catch {
                throw CompanyIntentError(message: "\(name)をリストに追加できませんでした。")
            }
            text = "\(name)をリストに追加しました。"
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// 要約はアプリでは作らない。直近の年度ごとの主要指標を文字列で返し、
/// ショートカットの「モデルを使用」や Siri の AI が要約・比較できるようにする。
struct CompanyAnalysisIntent: AppIntent {
    static let title: LocalizedStringResource = "会社の分析データを見る"
    static let description = IntentDescription("直近 5 期の売上高・利益率・ROIC・ROE・キャッシュフローなどを年度ごとに返します。ショートカットの AI で要約できます。")

    @Parameter(title: "会社名または証券コード", requestValueDialog: "どの会社の分析データを見ますか？")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$query)の分析データ")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let company = try await CompanyLookup.resolve(query)
        let response: FinancialsResponse
        do {
            response = try await APIClient.shared.financials(code: company.code)
        } catch {
            throw CompanyIntentError(message: "\(company.name)の分析データを取得できませんでした。")
        }
        let years = Array(Format.chronological(response.years).filter { !($0.fyEnd ?? "").isEmpty }.suffix(5))
        guard !years.isEmpty else {
            throw CompanyIntentError(message: "\(company.name)の分析データはまだ集計されていません。")
        }
        let blocks = years.map { year -> String in
            let currency = year.currency ?? response.currency
            return """
                \(Format.fyJapanese(year.fyEnd))
                売上高 \(Format.autoYen(year.sales, currency: currency))
                営業利益 \(Format.autoYen(year.operatingProfit, currency: currency))（営業利益率 \(Format.percent(year.operatingMargin))）
                純利益 \(Format.autoYen(year.netProfit, currency: currency))
                ROIC \(Format.percent(year.roic)) / ROE \(Format.percent(year.roe))
                営業CF \(Format.autoYen(year.cfo, currency: currency)) / 設備投資 \(Format.autoYen(year.capex, currency: currency)) / FCF \(Format.autoYen(Format.freeCashFlow(year), currency: currency))
                ネットD/E \(Format.times(year.netDe))
                """
        }
        let text = "\(company.name) 直近\(years.count)期の分析データ\n\n" + blocks.joined(separator: "\n\n")
        // 全文を読み上げさせない。数値は戻り値で次のアクション（AI など）へ渡す。
        return .result(value: text, dialog: IntentDialog(stringLiteral: "\(company.name)の直近\(years.count)期の分析データを返しました。"))
    }
}

/// 入力なし。端末に保存済みの開示フィード（RSS）から、最近有報を出した会社を新しい順に返す。
struct RecentFilingsIntent: AppIntent {
    static let title: LocalizedStringResource = "最近の有報を見る"
    static let description = IntentDescription("最近有価証券報告書を出した会社を、新しい順に返します。")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let items = await FeedRSSStore.shared.cachedItems() ?? []
        guard !items.isEmpty else {
            throw CompanyIntentError(message: "開示情報がまだ保存されていません。有報LABを一度開いてからもう一度お試しください。")
        }
        let text = items.prefix(5).map { item -> String in
            let name = Format.displayName(item.name, fallback: item.code)
            let date = item.submittedAt.isEmpty ? "" : " \(item.submittedAt)"
            return "\(name) \(item.code)\(date)"
        }.joined(separator: "\n")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// 銘柄を選ばないショートカット。App Shortcuts が登録されているかを確かめる入口にもなる。
struct OpenBlueTickerIntent: AppIntent {
    static let title: LocalizedStringResource = "有報LABを開く"
    static let description = IntentDescription("有報LABを開きます。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct BlueTickerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenBlueTickerIntent(),
            phrases: [
                "\(.applicationName)を開く",
                "\(.applicationName)を起動",
            ],
            shortTitle: "有報LABを開く",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
        AppShortcut(
            intent: SearchCompanyIntent(),
            phrases: [
                "\(.applicationName)で会社を検索",
                "\(.applicationName)で社名を検索",
            ],
            shortTitle: "会社名で検索",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: CompanyOverviewIntent(),
            phrases: [
                "\(.applicationName)で会社の概要を教えて",
                "\(.applicationName)で会社を調べる",
            ],
            shortTitle: "会社の概要",
            systemImageName: "building.2"
        )
        AppShortcut(
            intent: CompanyFinancialsIntent(),
            phrases: [
                "\(.applicationName)で会社の業績を教えて",
                "\(.applicationName)で会社の決算を見る",
            ],
            shortTitle: "最新の業績",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: CompanyAnalysisIntent(),
            phrases: [
                "\(.applicationName)で会社の分析データを見る",
                "\(.applicationName)で会社を分析",
            ],
            shortTitle: "分析データ",
            systemImageName: "chart.xyaxis.line"
        )
        AppShortcut(
            intent: FindCompaniesInTextIntent(),
            phrases: [
                "\(.applicationName)で文章から会社を探す",
                "\(.applicationName)でニュースの会社を調べる",
            ],
            shortTitle: "文章から会社を探す",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: FindCompaniesInImageIntent(),
            phrases: [
                "\(.applicationName)でスクリーンショットから会社を探す",
                "\(.applicationName)で画像から会社を探す",
            ],
            shortTitle: "画像から会社を探す",
            systemImageName: "photo"
        )
        AppShortcut(
            intent: OpenCompanyIntent(),
            phrases: [
                "\(.applicationName)で会社の結果を開く",
                "\(.applicationName)で会社の結果画面を見る",
            ],
            shortTitle: "結果画面を開く",
            systemImageName: "rectangle.portrait.and.arrow.right"
        )
        AppShortcut(
            intent: AddCompanyToWatchlistIntent(),
            phrases: [
                "\(.applicationName)のリストに会社を追加",
                "\(.applicationName)で会社をリストに追加",
            ],
            shortTitle: "リストに追加",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: RecentFilingsIntent(),
            phrases: [
                "\(.applicationName)で最近の有報を見る",
                "\(.applicationName)で新着の有報を教えて",
            ],
            shortTitle: "最近の有報",
            systemImageName: "doc.text"
        )
    }
}
