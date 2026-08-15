import Foundation

let assetsPathEnv = "BLUE_TICKER_ASSETS_PATH"

/// `assets/` 配下のファイルを env → CWD → 実行ファイル隣接 → Homebrew share の順で探す共通探索。
/// `resolveEdinetCSVURL`（`Services/MasterDataManager.swift`）・`resolvePriorityCodesCSVURL`
/// （`Services/PriorityIngestCodes.swift`）・標準タクソノミラベル解決（`Analysis/XBRLUtils.swift`）で共有する。
/// `Analysis/` は `Services/` を参照できないため（AGENTS.md 依存ルール）、この探索本体は
/// Service 非依存の `Utils/` に置く。
func resolveAssetFileURL(
    filename: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
    executableURL: URL? = Bundle.main.executableURL,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> URL? {
    if let dir = environment[assetsPathEnv], !dir.isEmpty {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(filename)
        if fileExists(url.path) { return url }
    }

    var candidates: [URL] = [
        URL(fileURLWithPath: currentDirectoryPath)
            .appendingPathComponent("assets/\(filename)")
    ]

    if let executableURL {
        let executableDir = executableURL.deletingLastPathComponent()
        candidates.append(
            executableDir.appendingPathComponent("assets/\(filename)")
        )
        candidates.append(
            executableDir
                .deletingLastPathComponent()
                .appendingPathComponent("share/blue-ticker/assets/\(filename)")
        )
    }

    return candidates.first { fileExists($0.path) }
}
