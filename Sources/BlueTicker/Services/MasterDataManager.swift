import Foundation

private let assetsPathEnv = "BLUE_TICKER_ASSETS_PATH"
private let legacyAssetsPathEnv = "MEBUKI_ASSETS_PATH"

// MARK: - MasterDataManager

actor MasterDataManager {
    private var stocks: [MasterStock] = []
    private var codeIndex: [String: MasterStock] = [:]
    private var isLoaded = false

    func loadIfNeeded() async {
        if !isLoaded { await reload() }
    }

    func reload() async {
        let path = resolveAssetsPath()
        guard let url = path else {
            fputs("[blue-ticker] Warning: data_j.csv が見つかりません。BLUE_TICKER_ASSETS_PATH を設定してください。\n", stderr)
            return
        }
        await loadCSV(from: url)
    }

    func search(_ query: String, limit: Int = 50) async -> [StockSearchResult] {
        await loadIfNeeded()
        let q = normalizeForSearch(query)
        if q.isEmpty { return [] }

        var results: [StockSearchResult] = []
        for stock in stocks {
            if stock.code == q || stock.coNameNormalized.contains(q) || stock.coName.contains(query) {
                results.append(StockSearchResult(
                    code: stock.code,
                    name: stock.coName,
                    sector: stock.s33nm,
                    market: stock.mktNm
                ))
                if results.count >= limit { break }
            }
        }
        return results
    }

    func getByCode(_ code: String) async -> MasterStock? {
        await loadIfNeeded()
        return codeIndex[code]
    }

    func allSectors() async -> [SectorSummary] {
        await loadIfNeeded()
        var counts: [String: (name: String, count: Int)] = [:]
        for stock in stocks {
            let code = stock.s33
            let existing = counts[code]
            counts[code] = (stock.s33nm, (existing?.count ?? 0) + 1)
        }
        return counts.map { SectorSummary(code: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.code < $1.code }
    }

    // MARK: - Private

    private func loadCSV(from url: URL) async {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("[blue-ticker] Warning: data_j.csv の読み込みに失敗しました。\n", stderr)
            return
        }

        var lines = content.components(separatedBy: "\n")
        guard let header = lines.first else { return }
        lines.removeFirst()

        let cols = parseCSVRow(header)
        guard let codeIdx = cols.firstIndex(of: "コード"),
              let nameIdx = cols.firstIndex(of: "銘柄名")
        else {
            fputs("[blue-ticker] Warning: data_j.csv のヘッダー形式が不正です。\n", stderr)
            return
        }
        let s33idx = cols.firstIndex(of: "33業種区分")
        let s33nmIdx = cols.firstIndex(of: "33業種名称")
        let s17idx = cols.firstIndex(of: "17業種区分")
        let s17nmIdx = cols.firstIndex(of: "17業種名称")
        let mktIdx = cols.firstIndex(of: "市場・商品区分")

        var loaded: [MasterStock] = []
        var index: [String: MasterStock] = [:]

        for line in lines {
            let fields = parseCSVRow(line)
            guard fields.count > max(codeIdx, nameIdx) else { continue }
            let code = fields[codeIdx].trimmingCharacters(in: .whitespaces)
            let name = fields[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { continue }
            let stock = MasterStock(
                code: code,
                coName: name,
                coNameUpper: name.uppercased(),
                coNameNormalized: normalizeForSearch(name),
                s33nm: s33nmIdx.map { $0 < fields.count ? fields[$0] : "" } ?? "",
                mktNm: mktIdx.map { $0 < fields.count ? fields[$0] : "" } ?? "",
                s33: s33idx.map { $0 < fields.count ? fields[$0] : "" } ?? "",
                s17nm: s17nmIdx.map { $0 < fields.count ? fields[$0] : "" } ?? "",
                s17: s17idx.map { $0 < fields.count ? fields[$0] : "" } ?? ""
            )
            loaded.append(stock)
            index[code] = stock
        }
        self.stocks = loaded
        self.codeIndex = index
        self.isLoaded = true
    }

    private func parseCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle() }
            else if ch == "," && !inQuotes { fields.append(current); current = "" }
            else { current.append(ch) }
        }
        fields.append(current)
        return fields
    }

    private func normalizeForSearch(_ name: String) -> String {
        // NFKC 正規化 + 大文字 + 中点除去 + スペース除去
        let nfkc = name.precomposedStringWithCompatibilityMapping.uppercased()
        return nfkc
            .replacingOccurrences(of: "・", with: "")
            .replacingOccurrences(of: "･", with: "")
            .components(separatedBy: .whitespaces).joined()
    }

    private func resolveAssetsPath() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let dir: String? = env[assetsPathEnv] ?? env[legacyAssetsPathEnv]
        if let d = dir, !d.isEmpty {
            let url = URL(fileURLWithPath: d).appendingPathComponent("data_j.csv")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // デフォルト: バイナリ横の assets/
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL
                .deletingLastPathComponent()
                .appendingPathComponent("assets/data_j.csv")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

let masterDataManager = MasterDataManager()
