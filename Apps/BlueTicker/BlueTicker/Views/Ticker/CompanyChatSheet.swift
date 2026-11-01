import FoundationModels
import SwiftUI

/// 結果画面のチャット。HIG のシートでハーフから開き、質問したら全高へ広げる。
/// 概要と数字の表で足りる質問は端末内の言語モデル（Foundation Models）で答え、有報の文章が要る質問
/// （理由・方針・リスク・内訳など。`ChatRouting`）はサーバーの `POST /v1/chat` へ送る。
/// 数字は `ChatFacts`（端末）とサーバーがコードで計算し、モデルには文章化だけをさせる。
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
            if let reason = model.deviceUnavailableReason {
                ChatNote(text: reason + "質問はすべて有報LABのサーバーで答えます。", systemImage: "info.circle")
            }
            promptSection
            ForEach(model.messages) { message in
                ChatBubble(message: message)
            }
            ChatNote(
                text: "数字だけの質問は端末内で、有報の内容に関わる質問は有報LABのサーバーで答えます。サーバーへ送った質問は回答を作るために外部の AI サービスへ渡し、有報LABでは保存しません。数字は表の値をご確認ください。",
                systemImage: "info.circle"
            )
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
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            bubble
            if let note = message.note {
                caption(note, systemImage: "info.circle")
            }
            if message.role == .assistant, !message.text.isEmpty, message.source == .server {
                caption(
                    "有報LABのサーバーで回答"
                        + (message.references.isEmpty ? "" : "（参照: " + message.references.joined(separator: "、") + "）"),
                    systemImage: "doc.text.magnifyingglass"
                )
            } else if !message.references.isEmpty {
                caption("参照: " + message.references.joined(separator: "、"), systemImage: "doc.text.magnifyingglass")
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func caption(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 6)
    }

    private var bubble: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Group {
                if message.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Theme.textMuted)
                        if let status = message.status {
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message.status ?? "回答を生成中")
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

    @Guide(description: "最も目立つ変化を1〜2文で。数字は下の表に出すので書かず、どの指標がどちらへ動いたかを言葉で書く")
    var highlight: String

    @Guide(description: "利用者が次に深掘りしたくなる短い質問。それぞれ20字以内", .count(3))
    var followUpSuggestions: [String]
}

/// 質問の振り分けの判定結果。
@Generable
enum ChatQuestionKind {
    /// 手元の数字の表だけで答えられる。
    case figures
    /// 有報の文章や表に無い情報が要る。
    case report
}

@Generable
struct ChatQuestionRoute {
    @Guide(description: "表の数字だけで答えられるなら figures、有報の文章や表に無い情報が要るなら report。迷ったら report")
    var kind: ChatQuestionKind
}

/// 決算期ごとの値を返すツール。取得済みの Waterfall から返すので通信しない。
struct FinancialYearTool: Tool {
    let name = "getFinancialYear"
    let description = "指定した決算期の売上高・営業利益・営業利益率・純利益・ROE・ROIC・従業員数と、前期からの変化の要因を返す"
    let facts: ChatFacts
    let log: ToolCallLog

    @Generable
    struct Arguments {
        @Guide(description: "決算期末の西暦年。例: 26年3月期なら2026")
        var fiscalYear: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let year = ChatFacts.normalizedFiscalYear(arguments.fiscalYear)
        let period = facts.years.last { $0.fiscalYear == year }.map { ChatFacts.periodLabel($0.fyEnd) }
        log.append(period.map { "\($0)の財務データ" } ?? "\(year)年の財務データ（該当なし）")
        return facts.yearDetail(fiscalYear: year)
    }
}

/// ツールが呼ばれた記録。回答の下に「参照」として出し、端末内で答えたのかを確かめられるようにする。
final class ToolCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

    /// 溜まった記録を取り出して空にする。
    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let drained = entries
        entries.removeAll()
        return drained
    }
}

@MainActor
@Observable
final class CompanyChatModel {
    enum Role {
        case user
        case assistant
    }

    enum Source {
        case device
        case server
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var role: Role
        var text: String
        var failed = false
        /// この回答のためにツールで参照したもの。
        var references: [String] = []
        /// どこで答えたか（端末内のモデルか、有報LABのサーバーか）。
        var source: Source = .device
        /// 回答を待つあいだの表示（「有報の「事業等のリスク」を読んでいます」など）。
        var status: String?
        /// 回答の下に添える注記（サーバーに届かず端末内で答えた、など）。
        var note: String?
    }

    let company: CompanyRef
    private(set) var isLoading = true
    private(set) var facts: ChatFacts?
    private(set) var loadError: String?
    /// 端末内モデルが使えない理由。nil なら使える。使えないときは質問をすべてサーバーへ送る。
    private(set) var deviceUnavailableReason: String?
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
    private let toolLog = ToolCallLog()
    private var exchanges: [ChatContext.Exchange] = []
    private var started = false

    /// 端末内モデルの文脈は約 4,000 トークン。会社説明はこの字数で切る。
    private static let overviewCharacterLimit = 200

    init(company: CompanyRef) {
        self.company = company
    }

    var canChat: Bool { facts != nil }

    private var deviceAvailable: Bool { deviceUnavailableReason == nil }

    func start() async {
        guard !started else { return }
        started = true
        deviceUnavailableReason = Self.unavailableReason()
        await loadData()
        isLoading = false
        guard let facts else { return }
        guard deviceAvailable else {
            // 端末内で生成できないときは API の Overview をそのまま概要に出し、質問はサーバーへ送る。
            overviewText = apiOverview.isEmpty ? nil : apiOverview
            suggestions = Self.fallbackSuggestions
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
        let destination = await route(question)
        do {
            let answer: String
            switch destination {
            case .device:
                answer = try await respond(to: question, at: index, facts: facts, retryOnOverflow: true)
            case .server:
                answer = try await respondOnServer(to: question, at: index, facts: facts)
            }
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
        _ = toolLog.drain()
        do {
            var latest = ""
            for try await snapshot in session.streamResponse(to: question) {
                latest = snapshot.content
                messages[index].text = ChatContext.normalizedDigits(latest)
            }
            var seen = Set<String>()
            messages[index].references = toolLog.drain().filter { seen.insert($0).inserted }
            return ChatContext.normalizedDigits(latest)
        } catch let error as LanguageModelSession.GenerationError {
            guard retryOnOverflow, case .exceededContextWindowSize = error else { throw error }
            // 文脈があふれたら、直近のやりとりだけを持ち越して作り直す。
            self.session = makeSession(facts: facts, carry: ChatContext.carriedExchanges(exchanges))
            messages[index].text = ""
            return try await respond(to: question, at: index, facts: facts, retryOnOverflow: false)
        }
    }

    /// どちらで答えるか。理由・リスクなどの語があればすぐサーバーへ。語で決まらない質問は端末内のモデルに
    /// 「表の数字で足りるか」を判定させる。判定できなければサーバーへ（端末内では浅い回答になりやすい）。
    private func route(_ question: String) async -> ChatRouting.Destination {
        guard deviceAvailable else { return .server }
        if ChatRouting.needsReport(question) { return .server }
        let session = LanguageModelSession { Self.routingInstructions }
        do {
            let response = try await session.respond(to: question, generating: ChatQuestionRoute.self)
            return response.content.kind == .figures ? .device : .server
        } catch {
            return .server
        }
    }

    private static let routingInstructions = """
    利用者が日本の上場企業について質問します。その質問が、手元の数字の表だけで答えられるかを判定します。
    表にあるのは、売上高・営業利益・営業利益率・純利益・ROE・ROIC・従業員数の各決算期の値と前期比、事業利益の前期差の要因分解（売上・粗利率・販管費）、粗利率、販管費率、ROE の分解、従業員1人あたり売上高です。
    これらの値や増減、どれが大きく動いたかを聞く質問は figures です。
    事業の中身、戦略、競合との比較、具体的な理由、今後の見通し、内訳など、表に無い情報や有価証券報告書の文章が要る質問は report です。
    迷ったら report にします。
    """

    /// 有報の文章が要る質問をサーバーで答える。届かないときは、端末内で答えられるならそちらへ回す。
    private func respondOnServer(to question: String, at index: Int, facts: ChatFacts) async throws -> String {
        messages[index].source = .server
        messages[index].status = "有報LABのサーバーに問い合わせています"
        let body = ServerChatRequest.body(code: company.code, exchanges: exchanges, question: question)
        do {
            var text = ""
            for try await event in try await APIClient.shared.chat(body: body) {
                switch event {
                case .delta(let delta):
                    text += delta
                    messages[index].text = ChatContext.normalizedDigits(text)
                case .tool(let label):
                    if !messages[index].references.contains(label) {
                        messages[index].references.append(label)
                    }
                    messages[index].status = "\(label)を読んでいます"
                case .done:
                    break
                case .failure(let message):
                    throw ServerChatFailure(message: message)
                }
            }
            guard !text.isEmpty else { throw ServerChatFailure(message: "回答を取得できませんでした。") }
            return messages[index].text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard deviceAvailable else { throw error }
            messages[index] = Message(role: .assistant, text: "", note: Self.serverFallbackNote(for: error))
            return try await respond(to: question, at: index, facts: facts, retryOnOverflow: true)
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
                overviewText = partial.overview.map(ChatContext.normalizedDigits)
                highlightText = partial.highlight.map(ChatContext.normalizedDigits)
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
        return LanguageModelSession(tools: [FinancialYearTool(facts: facts, log: toolLog)]) {
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
    数字で説明したうえで、事業上の具体的な理由（製品、価格、為替など）は手元の資料に無いと一言添えます。
    数字は半角の算用数字で、与えられた表記のまま書きます。同じ内容を繰り返しません。
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
            (currency ?? "JPY") == "JPY"
                ? ChatFacts.yenText(amount)
                : Format.autoYen(amount, currency: currency)
        }
    }

    /// 画面には「AFM」と出さない。続けて「質問はすべて有報LABのサーバーで答えます。」を添える。
    private static func unavailableReason() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            guard model.supportsLocale(Locale(identifier: "ja_JP")) else {
                return "この端末の言語モデルは日本語に対応していません。"
            }
            return nil
        case .unavailable(.deviceNotEligible):
            return "この端末は Apple Intelligence に対応していません。"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence がオフになっています。"
        case .unavailable(.modelNotReady):
            return "端末内の言語モデルを準備しています。"
        case .unavailable:
            return "いまは端末内の言語モデルを使えません。"
        }
    }

    /// サーバーの上限（429）は HAPIS のエンドポイント上限（1 分 5 回・1 日 10 回）。
    private static let serverLimitText = "有報LABのサーバーでの回答は、1分に5回・1日に10回までです。"

    private static func serverFallbackNote(for error: Error) -> String {
        if case APIClientError.http(let status, _) = error, status == 429 {
            return serverLimitText + "上限に達したため端末内で答えました（有報の文章は読んでいません）。"
        }
        return "有報LABのサーバーにつながらないため、端末内で答えました（有報の文章は読んでいません）。"
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? ServerChatFailure {
            return failure.message
        }
        if case APIClientError.http(let status, _) = error {
            if status == 429 { return serverLimitText + "時間をおいてお試しください。" }
            return "いまは有報LABのサーバーで回答できません。時間をおいてお試しください。"
        }
        if error is APIClientError {
            return "有報LABのサーバーにつながりませんでした。通信状況を確かめてお試しください。"
        }
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

/// サーバーが `error` イベントで返した失敗。
struct ServerChatFailure: Error {
    let message: String
}
