import FoundationModels
import SwiftUI

/// 結果画面のチャット。HIG のシートでハーフから開き、質問したら全高へ広げる。
/// 文章は端末内の言語モデル（Foundation Models）だけで作り、会話はサーバーへ送らない。
/// 数字は `ChatFacts` がコードで計算し、モデルには文章化だけをさせる。
struct CompanyChatSheet: View {
    var company: CompanyRef
    @Environment(\.dismiss) private var dismiss
    @State private var model: CompanyChatModel
    @State private var detent: PresentationDetent = .medium
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private let bottomID = "chat-bottom"

    init(company: CompanyRef) {
        self.company = company
        _model = State(initialValue: CompanyChatModel(company: company))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        content
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollToken) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .background(Theme.shell.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if model.canChat {
                    inputBar
                }
            }
            .navigationTitle(Format.displayName(company.name, fallback: company.code))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", systemImage: "xmark", role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if let facts = model.facts {
            digestSection
            ChatFactsTable(facts: facts)
            if let unavailable = model.unavailableMessage {
                ChatNote(text: unavailable, systemImage: "info.circle")
            } else {
                promptSection
                ForEach(model.messages) { message in
                    ChatBubble(message: message)
                }
                ChatNote(
                    text: "文章は端末内で生成しています。数字は表の値をご確認ください。",
                    systemImage: "iphone"
                )
            }
        } else {
            ChatNote(
                text: model.loadError ?? "財務データが無いため、チャットは使えません。",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    /// 概要と補足・特筆点。生成できない端末では API の Overview だけを出す。
    @ViewBuilder
    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let overview = model.overviewText, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(Theme.text)
            } else if model.isDigesting {
                placeholderLines(2)
            }
            if let highlight = model.highlightText, !highlight.isEmpty {
                Text(highlight)
                    .font(.body)
                    .foregroundStyle(Theme.textMuted)
            } else if model.isDigesting {
                placeholderLines(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: model.overviewText)
    }

    /// 促しと質問候補チップ。
    @ViewBuilder
    private var promptSection: some View {
        if !model.suggestions.isEmpty || !model.isDigesting {
            VStack(alignment: .leading, spacing: 10) {
                Text("深掘りしたい点はありますか？")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button {
                        submit(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .disabled(model.isResponding)
                }
            }
        }
    }

    /// 入力欄。後ろの会話が透けて文字に重ならないよう、欄の背後はシートの地色で塗る。
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("質問を入力", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit(draft) }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                submit(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(canSend ? Color.white : Theme.textMuted)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Theme.accent : Theme.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("送信")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.shell.ignoresSafeArea(edges: .bottom))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isResponding
    }

    private func submit(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !model.isResponding else { return }
        draft = ""
        // 深掘りを始めたら全高へ。ハーフのままだと回答が入力欄に隠れる。
        withAnimation { detent = .large }
        Task { await model.send(question) }
    }

    private func placeholderLines(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.elevated)
                    .frame(height: 14)
                    .frame(maxWidth: index == count - 1 ? 220 : .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel("生成中")
    }
}

// MARK: - 部品

/// 根拠の数字。文章で触れた指標を直近 2 期で並べる。値は API の値をそのまま整形する。
private struct ChatFactsTable: View {
    var facts: ChatFacts

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("")
                Text(facts.previousPeriod ?? "")
                    .gridColumnAlignment(.trailing)
                Text(facts.latestPeriod)
                    .gridColumnAlignment(.trailing)
                Text("前期比")
                    .gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)
            Divider()
                .gridCellUnsizedAxes(.horizontal)
            ForEach(facts.rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(Theme.textMuted)
                    Text(row.previous)
                        .foregroundStyle(Theme.textMuted)
                    Text(row.latest)
                        .foregroundStyle(Theme.text)
                    Text(changeText(row))
                        .foregroundStyle(changeColor(row))
                }
                .font(.subheadline.monospacedDigit())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bltCardSurface()
        .accessibilityElement(children: .contain)
    }

    private func changeText(_ row: ChatFactRow) -> String {
        if let change = row.change { return change }
        switch row.direction {
        case .turnedPositive?, .turnedNegative?: return row.direction?.word ?? "—"
        default: return "—"
        }
    }

    private func changeColor(_ row: ChatFactRow) -> Color {
        switch row.direction {
        case .up?, .turnedPositive?: Theme.positive
        case .down?, .turnedNegative?: Theme.negative
        default: Theme.textMuted
        }
    }
}

private struct ChatBubble: View {
    var message: CompanyChatModel.Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Group {
                if message.text.isEmpty {
                    ProgressView()
                        .tint(Theme.textMuted)
                        .accessibilityLabel("回答を生成中")
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                }
            }
            .font(.body)
            .foregroundStyle(message.failed ? Theme.textMuted : Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user ? Theme.accent.opacity(0.28) : Theme.card,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            if message.role == .assistant { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

private struct ChatNote: View {
    var text: String
    var systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - モデル

@Generable
struct CompanyChatDigest {
    @Guide(description: "何を手がける会社かと、業績の向きを2文以内で。金額や比率の数字は書かない")
    var overview: String

    @Guide(description: "最も目立つ変化を1〜2文で。数字を書くときは与えられた表記をそのまま使う")
    var highlight: String

    @Guide(description: "利用者が次に深掘りしたくなる短い質問。それぞれ20字以内", .count(3))
    var followUpSuggestions: [String]
}

/// 決算期ごとの値を返すツール。取得済みの Waterfall から返すので通信しない。
struct FinancialYearTool: Tool {
    let name = "getFinancialYear"
    let description = "指定した決算期の売上高・営業利益・営業利益率・純利益・ROE・ROIC・従業員数と、前期からの変化の要因を返す"
    let facts: ChatFacts

    @Generable
    struct Arguments {
        @Guide(description: "決算期末の西暦年。例: 26年3月期なら2026")
        var fiscalYear: Int
    }

    func call(arguments: Arguments) async throws -> String {
        facts.yearDetail(fiscalYear: arguments.fiscalYear)
    }
}

@MainActor
@Observable
final class CompanyChatModel {
    enum Role {
        case user
        case assistant
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var role: Role
        var text: String
        var failed = false
    }

    let company: CompanyRef
    private(set) var isLoading = true
    private(set) var facts: ChatFacts?
    private(set) var loadError: String?
    /// 生成できない理由。nil なら端末内モデルが使える。
    private(set) var unavailableMessage: String?
    private(set) var overviewText: String?
    private(set) var highlightText: String?
    private(set) var isDigesting = false
    private(set) var suggestions: [String] = []
    private(set) var messages: [Message] = []
    private(set) var isResponding = false
    /// 増えるたびにシートを末尾へスクロールする。
    private(set) var scrollToken = 0

    private var apiOverview = ""
    private var session: LanguageModelSession?
    private var exchanges: [ChatContext.Exchange] = []
    private var started = false

    /// 端末内モデルの文脈は約 4,000 トークン。会社説明はこの字数で切る。
    private static let overviewCharacterLimit = 200

    init(company: CompanyRef) {
        self.company = company
    }

    var canChat: Bool { facts != nil && unavailableMessage == nil }

    func start() async {
        guard !started else { return }
        started = true
        unavailableMessage = Self.unavailableReason()
        await loadData()
        isLoading = false
        guard let facts else { return }
        guard unavailableMessage == nil else {
            // 生成できない端末は API の Overview をそのまま概要に出す。
            overviewText = apiOverview.isEmpty ? nil : apiOverview
            return
        }
        let session = makeSession(facts: facts, carry: nil)
        session.prewarm()
        self.session = session
        await generateDigest(facts: facts)
    }

    func send(_ question: String) async {
        guard canChat, !isResponding, let facts else { return }
        messages.append(Message(role: .user, text: question))
        let index = messages.count
        messages.append(Message(role: .assistant, text: ""))
        isResponding = true
        scrollToken += 1
        defer {
            isResponding = false
            scrollToken += 1
        }
        do {
            let answer = try await respond(to: question, at: index, facts: facts, retryOnOverflow: true)
            exchanges.append(ChatContext.Exchange(question: question, answer: answer))
        } catch {
            messages[index].text = Self.message(for: error)
            messages[index].failed = true
        }
    }

    // MARK: - 生成

    private func respond(
        to question: String,
        at index: Int,
        facts: ChatFacts,
        retryOnOverflow: Bool
    ) async throws -> String {
        let session = self.session ?? makeSession(facts: facts, carry: nil)
        self.session = session
        do {
            var latest = ""
            for try await snapshot in session.streamResponse(to: question) {
                latest = snapshot.content
                messages[index].text = latest
            }
            return latest
        } catch let error as LanguageModelSession.GenerationError {
            guard retryOnOverflow, case .exceededContextWindowSize = error else { throw error }
            // 文脈があふれたら、直近のやりとりだけを持ち越して作り直す。
            self.session = makeSession(facts: facts, carry: ChatContext.carriedExchanges(exchanges))
            messages[index].text = ""
            return try await respond(to: question, at: index, facts: facts, retryOnOverflow: false)
        }
    }

    private func generateDigest(facts: ChatFacts) async {
        isDigesting = true
        defer { isDigesting = false }
        let session = LanguageModelSession {
            Self.baseInstructions
        }
        let prompt = """
        次の会社について、概要と特筆点と質問候補を作ってください。

        \(companyContext(facts: facts))
        """
        do {
            var lastSuggestions: [String] = []
            for try await snapshot in session.streamResponse(to: prompt, generating: CompanyChatDigest.self) {
                let partial = snapshot.content
                overviewText = partial.overview
                highlightText = partial.highlight
                if let suggestions = partial.followUpSuggestions {
                    lastSuggestions = suggestions
                }
            }
            suggestions = lastSuggestions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            // 生成に失敗しても表と入力欄は使える。概要は API の Overview で代える。
            if (overviewText ?? "").isEmpty, !apiOverview.isEmpty {
                overviewText = apiOverview
            }
        }
        if suggestions.isEmpty {
            suggestions = Self.fallbackSuggestions
        }
    }

    private func makeSession(facts: ChatFacts, carry: String?) -> LanguageModelSession {
        var text = Self.baseInstructions + "\n\n" + Self.chatRules + "\n\n" + companyContext(facts: facts)
        if let carry {
            text += "\n\nこれまでのやりとり（抜粋）:\n" + carry
        }
        let instructions = text
        return LanguageModelSession(tools: [FinancialYearTool(facts: facts)]) {
            instructions
        }
    }

    private func companyContext(facts: ChatFacts) -> String {
        var lines = ["会社: \(Format.displayName(company.name, fallback: company.code))（銘柄コード \(company.code)）"]
        if !company.sector.isEmpty {
            lines.append("業種: \(company.sector)")
        }
        if !apiOverview.isEmpty {
            lines.append("事業の説明: " + ChatContext.clipped(apiOverview, maxCharacters: Self.overviewCharacterLimit))
        }
        lines.append("数字（計算済み。表記を変えずに使う）:")
        lines.append(facts.promptLines)
        if !facts.driverLines.isEmpty {
            lines.append("変化の要因（計算済み。表記を変えずに使う）:")
            lines.append(contentsOf: facts.driverLines)
        }
        lines.append("取得できる決算期: " + facts.periodLabels.joined(separator: "、"))
        return lines.joined(separator: "\n")
    }

    private static let baseInstructions = """
    あなたは日本の上場企業の決算を、投資に詳しくない人へやさしく説明するアシスタントです。日本語で答えます。
    数字は与えられたものだけを、表記を変えずに使います。計算や推測で新しい数字を作りません。
    増加・減少などの向きは、与えられた言葉に従います。
    """

    private static let chatRules = """
    回答は3〜4文にします。
    「なぜ」「要因」を聞かれたら、まず「変化の要因」の数字で説明します。例えば利益率なら、粗利率と販管費率のどちらが動いたか、事業利益の前期差のうち売上・粗利率・販管費の要因がそれぞれいくらかを答えます。
    従業員数の影響は、従業員1人あたり売上高の変化で説明します。ROE の変化は、純利益率・総資産回転率・財務レバレッジのどれが動いたかで説明します。
    数字で説明したうえで、事業上の具体的な理由（製品、価格、為替など）は手元の資料に無いと一言添えます。「データがありません」だけで終えません。
    表に無い決算期の値や要因が必要なときは getFinancialYear を使います。
    株価と将来の業績予想は扱いません。投資の勧誘や売買の判断はしません。
    """

    private static let fallbackSuggestions = [
        "利益率が変わった理由は？",
        "過去5年の売上の推移は？",
        "資本効率はどう？",
    ]

    // MARK: - 入力と端末

    private func loadData() async {
        let code = company.code
        var waterfall = await APIClient.shared.cachedWaterfall(code: code)
        do {
            waterfall = try await APIClient.shared.waterfall(code: code)
        } catch APIClientError.http(let status, let message) where status == 404 {
            waterfall = nil
            loadError = message.isEmpty ? "財務データは未集計です" : message
        } catch {
            if waterfall == nil { loadError = error.localizedDescription }
        }

        var overview = await APIClient.shared.cachedOverview(code: code)
        if overview == nil {
            overview = try? await APIClient.shared.overview(code: code)
        }
        apiOverview = overview?.overview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let waterfall else { return }
        let currency = waterfall.currency ?? Format.latestYear(waterfall.years)?.currency
        let years = waterfall.years.compactMap { year -> ChatFactYear? in
            guard let fyEnd = year.fyEnd else { return nil }
            return ChatFactYear(
                fyEnd: fyEnd,
                sales: year.sales,
                operatingProfit: year.operatingProfit,
                operatingMargin: year.operatingMargin,
                netProfit: year.netProfit,
                roe: year.roe,
                roic: year.roic,
                employees: year.employees,
                grossProfitMargin: year.grossProfitMargin,
                sga: year.sga,
                businessProfitChange: year.businessProfitChange,
                salesChangeImpact: year.salesChangeImpact,
                grossMarginChangeImpact: year.grossMarginChangeImpact,
                sgaChangeImpact: year.sgaChangeImpact,
                netMargin: year.netMargin,
                assetTurnover: year.assetTurnover,
                financialLeverage: year.financialLeverage
            )
        }
        facts = ChatFacts(years: years) { amount in
            Format.autoYen(amount, currency: currency)
        }
    }

    /// 画面には「AFM」と出さない。
    private static func unavailableReason() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            guard model.supportsLocale(Locale(identifier: "ja_JP")) else {
                return "この端末の言語モデルが日本語に対応していないため、文章の生成と質問は使えません。"
            }
            return nil
        case .unavailable(.deviceNotEligible):
            return "この端末は Apple Intelligence に対応していないため、文章の生成と質問は使えません。"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "設定アプリで Apple Intelligence をオンにすると、文章の生成と質問が使えます。"
        case .unavailable(.modelNotReady):
            return "端末内の言語モデルを準備しています。しばらくしてから開き直してください。"
        case .unavailable:
            return "いまは文章の生成と質問が使えません。"
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else {
            return "回答を作れませんでした。もう一度お試しください。"
        }
        switch error {
        case .guardrailViolation:
            return "この質問にはお答えできません。聞き方を変えてお試しください。"
        case .exceededContextWindowSize:
            return "会話が長くなったため続けられません。シートを閉じて開き直してください。"
        case .unsupportedLanguageOrLocale:
            return "日本語で質問してください。"
        case .assetsUnavailable:
            return "端末内の言語モデルを準備しています。しばらくしてからお試しください。"
        default:
            return "回答を作れませんでした。もう一度お試しください。"
        }
    }
}
