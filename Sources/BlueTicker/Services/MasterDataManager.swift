import Foundation

private let edinetCsvFilename = "EdinetcodeDlInfo.csv"
/// EDINET「提出者種別」のうち、国内上場企業の取り込み対象から除外する値。
private let foreignFilerType = "外国法人・組合"

func resolveEdinetCSVURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    executableURL: URL? = Bundle.main.executableURL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> URL? {
    resolveAssetFileURL(
        filename: edinetCsvFilename, environment: environment,
        currentDirectoryPath: currentDirectoryPath, executableURL: executableURL,
        fileExists: fileExists)
}

/// Neon スナップショット適用など、CSV を書き込む先を解決する。
/// `BLUE_TICKER_ASSETS_PATH` が設定されていればファイル未存在でもそのパスを返す（ブートストラップ用）。
/// env 未設定時は既存ファイルがある読み取りパスへフォールバックする。
func resolveEdinetCSVWriteURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    executableURL: URL? = Bundle.main.executableURL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> URL? {
    if let dir = environment[assetsPathEnv], !dir.isEmpty {
        return URL(fileURLWithPath: dir).appendingPathComponent(edinetCsvFilename)
    }
    return resolveEdinetCSVURL(
        environment: environment,
        currentDirectoryPath: currentDirectoryPath,
        executableURL: executableURL,
        fileExists: fileExists
    )
}

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
            printError("[blue-ticker] Warning: \(edinetCsvFilename) が見つかりません。BLUE_TICKER_ASSETS_PATH を設定してください。\n")
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
                    market: stock.mktNm,
                    location: stock.location
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

    /// 上場（EDINET「上場区分」==「上場」）かつ国内法人・組合（外国法人・組合を除く）の
    /// 4 桁証券コード集合。financials/filing-sections 取り込みの対象ユニバース（東証上場の国内企業）を
    /// EDINET 公式 CSV から導出する（TOPIX/日経の構成銘柄リストは編集著作物の懸念があるため使わない）。
    /// 上場廃止で CSV から消えた企業は自然に含まれない（別途の除外処理は不要）。
    func listedCodes() async -> Set<String> {
        await loadIfNeeded()
        return Set(
            stocks.filter { $0.mktNm == "上場" && $0.filerType != foreignFilerType }.map { $0.code }
        )
    }

    // MARK: - Private

    private func loadCSV(from url: URL) async {
        guard let data = try? Data(contentsOf: url) else {
            printError("[blue-ticker] Warning: \(edinetCsvFilename) の読み込みに失敗しました。\n")
            return
        }
        // EdinetcodeDlInfo.csv は Windows Shift-JIS（CP932）エンコード。
        // .shiftJIS は Linux Foundation 非対応のため iconv に一本化する（decodeCP932 参照）。
        let raw = decodeCP932(data)
            ?? String(data: data, encoding: .utf8)
        guard let content = raw else {
            printError("[blue-ticker] Warning: \(edinetCsvFilename) のエンコード変換に失敗しました。\n")
            return
        }

        var lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // 1行目: メタデータ行（ダウンロード実行日 ...）をスキップ
        guard lines.count >= 2 else { return }
        lines.removeFirst()

        // 2行目: ヘッダー
        guard let header = lines.first else { return }
        lines.removeFirst()

        let cols = parseCSVRow(header)
        let normalizedCols = cols.map(normalizeHeaderName)
        guard let codeIdx = normalizedCols.firstIndex(of: normalizeHeaderName("証券コード")),
              let nameIdx = normalizedCols.firstIndex(of: normalizeHeaderName("提出者名"))
        else {
            printError("[blue-ticker] Warning: \(edinetCsvFilename) のヘッダー形式が不正です。\n")
            return
        }
        let industryIdx = normalizedCols.firstIndex(of: normalizeHeaderName("提出者業種"))
        let listingIdx = normalizedCols.firstIndex(of: normalizeHeaderName("上場区分"))
        let locationIdx = normalizedCols.firstIndex(of: normalizeHeaderName("所在地"))
        let filerTypeIdx = normalizedCols.firstIndex(of: normalizeHeaderName("提出者種別"))

        var loaded: [MasterStock] = []
        var index: [String: MasterStock] = [:]

        for line in lines {
            let fields = parseCSVRow(line)
            guard fields.count > max(codeIdx, nameIdx) else { continue }
            // EDINET証券コードは5桁（4桁TSEコード + "0"）。ユーザー向けは末尾を除いた4桁
            let secCode = normalizeSecurityCode(fields[codeIdx])
            guard secCode.count == 5, secCode.last == "0" else { continue }
            let code = String(secCode.dropLast())
            let name = fields[nameIdx].trimmingCharacters(in: CharacterSet.whitespaces)
            guard !name.isEmpty else { continue }
            let industry: String
            if let idx = industryIdx, idx < fields.count {
                industry = fields[idx].trimmingCharacters(in: CharacterSet.whitespaces)
            } else {
                industry = ""
            }
            let market: String
            if let idx = listingIdx, idx < fields.count {
                market = fields[idx].trimmingCharacters(in: CharacterSet.whitespaces)
            } else {
                market = ""
            }
            let location: String
            if let idx = locationIdx, idx < fields.count {
                location = fields[idx].trimmingCharacters(in: CharacterSet.whitespaces)
            } else {
                location = ""
            }
            let filerType: String
            if let idx = filerTypeIdx, idx < fields.count {
                filerType = fields[idx].trimmingCharacters(in: CharacterSet.whitespaces)
            } else {
                filerType = ""
            }
            let stock = MasterStock(
                code: code,
                coName: name,
                coNameUpper: name.uppercased(),
                coNameNormalized: normalizeForSearch(name),
                s33nm: industry,
                mktNm: market,
                location: location,
                s33: industry,
                filerType: filerType
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

    private func normalizeHeaderName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}\""))
            .precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private func normalizeSecurityCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .precomposedStringWithCompatibilityMapping
            .uppercased()
    }

    private func resolveAssetsPath() -> URL? {
        resolveEdinetCSVURL()
    }
}

let masterDataManager = MasterDataManager()

/// Neon 等の外部ストアから取得した EDINET コードリスト CSV（生バイト列）を反映する。
/// 書き込み用パスへ保存してから MasterDataManager をリロードする。
/// パス未解決・ディレクトリ作成失敗・書き込み失敗は false（戻り値パターン）。BltServerCore の定期ポーリングから呼ばれる。
public func applyEdinetMasterDataSnapshot(_ data: Data) async -> Bool {
    guard let url = resolveEdinetCSVWriteURL() else { return false }
    let directory = url.deletingLastPathComponent()
    guard (try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )) != nil else { return false }
    guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
    await masterDataManager.reload()
    return true
}
