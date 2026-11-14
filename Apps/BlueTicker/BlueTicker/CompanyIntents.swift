import AppIntents
import Foundation

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
    static func resolve(_ raw: String) async throws -> (code: String, name: String) {
        let hits = try await search(raw)
        let code = normalized(raw).uppercased()
        let hit = hits.first(where: { $0.code.uppercased() == code }) ?? hits[0]
        return (hit.code, Format.displayName(hit.name, fallback: hit.code))
    }
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
