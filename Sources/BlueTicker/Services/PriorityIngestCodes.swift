import Foundation

private let priorityCodesCsvFilename = "nikkei225.csv"

func resolvePriorityCodesCSVURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    executableURL: URL? = Bundle.main.executableURL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> URL? {
    resolveAssetFileURL(
        filename: priorityCodesCsvFilename, environment: environment,
        currentDirectoryPath: currentDirectoryPath, executableURL: executableURL,
        fileExists: fileExists)
}

/// `assets/nikkei225.csv`（ユーザーが用意する日経225等の優先コード一覧）から証券コード集合を読み込む。
/// 指数構成銘柄そのものは編集著作物のためリポジトリ・配布物には含めない（`.gitignore` 参照。ローカル専用ファイル）。
///
/// Web サイトからのコピペ由来でセクション見出し行・ヘッダー行・改行混入等の崩れがあり得るため、
/// 各行の先頭カラムが証券コード形式（先頭が数字の英数字4文字）に一致する行だけを拾う。
/// 未検出・読み込み失敗は空集合（呼び出し側は優先なしにフォールバックする＝戻り値パターン）。
func loadPriorityIngestCodes(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    executableURL: URL? = Bundle.main.executableURL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> Set<String> {
    guard
        let url = resolvePriorityCodesCSVURL(
            environment: environment, currentDirectoryPath: currentDirectoryPath,
            executableURL: executableURL, fileExists: fileExists)
    else { return [] }
    guard let data = try? Data(contentsOf: url), let content = String(data: data, encoding: .utf8)
    else {
        printError("[blue-ticker] Warning: \(priorityCodesCsvFilename) の読み込みに失敗しました（UTF-8 のみ対応）。\n")
        return []
    }

    var codes = Set<String>()
    let lines = content
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
    for line in lines {
        let firstField = String(line.prefix { $0 != "," })
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .precomposedStringWithCompatibilityMapping
            .uppercased()
        if isSecurityCodeShaped(firstField) {
            codes.insert(firstField)
        }
    }
    return codes
}

/// 証券コード形式（先頭1桁が数字の ASCII 英数字4文字。例: "6501" "285A"）かを判定する。
private func isSecurityCodeShaped(_ token: String) -> Bool {
    guard token.count == 4, let first = token.first, first.isASCII, first.isNumber else { return false }
    return token.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter) }
}
