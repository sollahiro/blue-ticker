import ArgumentParser
import Foundation

// analyze / summarize コマンドが共有する財務データ取得・テーブル描画ヘルパー。
// 両コマンドは取得処理・JSON 出力・表組みプリミティブが共通で、
// 人間向けテーブルの中身だけが異なる。

// MARK: - データ取得

/// 銘柄分析に必要なクライアント群と会社メタ情報。
struct AnalysisContext {
    let code: String
    let name: String
    let client: EdinetAPIClient
    let cacheManager: CacheManager
}

enum MetricsLoader {
    /// API キー検証・銘柄コード検証・クライアント構築・会社名解決をまとめて行う。
    /// 失敗時は stderr へ出力し `ExitCode.failure` を投げる。
    static func prepare(rawCode: String) async throws -> AnalysisContext {
        let apiKey = await settingsStore.get(.edinetApiKey)
        guard let key = apiKey, !key.isEmpty else {
            printError("エラー: EDINET API キーが設定されていません。ticker config set --edinet-api-key <KEY> で設定してください。\n")
            throw ExitCode.failure
        }

        let codeTrimmed = rawCode.trimmingCharacters(in: .whitespaces)
        guard !codeTrimmed.isEmpty else {
            printError("エラー: 銘柄コードを指定してください。\n")
            throw ExitCode.failure
        }

        let cacheDirStr = await settingsStore.get(.cacheDir) ?? ""
        let cacheDir = URL(fileURLWithPath: cacheDirStr)
        let store = EdinetCacheStore(cacheDir: edinetCacheDir(cacheDir))
        let client = EdinetAPIClient(apiKey: key, cacheStore: store)
        let cacheManager = CacheManager(cacheDir: derivedCacheDir(cacheDir))

        let masterDataManager = MasterDataManager()
        await masterDataManager.loadIfNeeded()
        let info = await masterDataManager.getByCode(codeTrimmed)

        return AnalysisContext(
            code: codeTrimmed,
            name: info?.coName ?? codeTrimmed,
            client: client,
            cacheManager: cacheManager
        )
    }
}

// MARK: - JSON 出力

enum MetricsJSON {
    static func print(_ result: MetricsResult) {
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let data = try? JSONEncoder().encode(result),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let outData = try? JSONSerialization.data(withJSONObject: dict, options: opts),
           let str = String(data: outData, encoding: .utf8) {
            Swift.print(str)
        }
    }

    static func print(_ periods: [HalfPeriod]) {
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let data = try? JSONEncoder().encode(periods),
           let arr = try? JSONSerialization.jsonObject(with: data),
           let outData = try? JSONSerialization.data(withJSONObject: arr, options: opts),
           let str = String(data: outData, encoding: .utf8) {
            Swift.print(str)
        }
    }
}

// MARK: - 表組みプリミティブ

enum MetricsTable {
    static let labelWidth = 22
    static let colWidth = 11

    static func padRight(_ s: String, width: Int = labelWidth) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }

    static func padLeft(_ s: String, width: Int = colWidth) -> String {
        s.count >= width ? String(s.prefix(width)) : String(repeating: " ", count: width - s.count) + s
    }

    static func separator(columns: Int) -> String {
        String(repeating: "-", count: labelWidth + colWidth * columns)
    }

    /// 年次列ラベル（例: "23/03"、2Q は "(2Q)" 付き）。
    static func yearColumnLabel(_ p: YearEntry) -> String {
        let fy = p.fyEnd ?? "不明"
        let (year, month) = extractYearMonth(fy)
        var label: String
        if let y = year, let m = month {
            label = "\(y % 100)/\(String(format: "%02d", m))"
        } else {
            label = fy
        }
        if (p.rawData.curPerType ?? "FY") == "2Q" { label += "(2Q)" }
        return label
    }

    /// ヘッダー行（左ラベル + 各列ラベル）と区切り線を出力する。
    static func printHeader(title: String, columnLabels: [String]) {
        var header = padRight(title)
        for label in columnLabels { header += padLeft(label) }
        let sep = separator(columns: columnLabels.count)
        printError(sep + "\n")
        printError(header + "\n")
        printError(sep + "\n")
    }

    /// 数値メトリクス行を出力する（全列 nil の行はスキップ）。
    static func printNumericRows<T>(_ periods: [T], _ metrics: [(String, (T) -> Double?)], decimals: Int = 2) {
        for (label, getter) in metrics {
            let vals = periods.map { getter($0) }
            if vals.allSatisfy({ $0 == nil }) { continue }
            var row = padRight(label)
            for val in vals {
                row += val.map { padLeft(String(format: "%.\(decimals)f", $0)) } ?? padLeft("-")
            }
            printError(row + "\n")
        }
    }

    /// 前年差メトリクス行を出力する。
    /// getter は (当期, 前期) を受け取る。`priors[i]` が当期 `periods[i]` の比較対象（前期）で、
    /// nil の列は前期が無いため "-"。年次・半期で前期の取り方が異なるため呼び出し側で priors を与える。
    /// 全列 nil の行はスキップ。
    static func printDeltaRows<T>(_ periods: [T], priors: [T?], _ metrics: [(String, (_ cur: T, _ prior: T) -> Double?)], decimals: Int = 2) {
        for (label, getter) in metrics {
            let vals: [Double?] = periods.indices.map { i in
                guard let prior = priors[i] else { return nil }
                return getter(periods[i], prior)
            }
            if vals.allSatisfy({ $0 == nil }) { continue }
            var row = padRight(label)
            for val in vals {
                row += val.map { padLeft(String(format: "%.\(decimals)f", $0)) } ?? padLeft("-")
            }
            printError(row + "\n")
        }
    }

    /// 文字列メトリクス行を出力する（全列 nil の行はスキップ）。
    static func printStringRows<T>(_ periods: [T], _ metrics: [(String, (T) -> String?)]) {
        for (label, getter) in metrics {
            let vals = periods.map { getter($0) }
            if vals.allSatisfy({ $0 == nil }) { continue }
            var row = padRight(label)
            for val in vals { row += padLeft(val ?? "-") }
            printError(row + "\n")
        }
    }
}
