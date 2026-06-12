import Foundation

private let userDataEnv = "BLUE_TICKER_USER_DATA_PATH"
private let configDirName = "blue-ticker"

func defaultUserDataPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    if let override = environment[userDataEnv] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return defaultConfigRoot().appendingPathComponent(configDirName, isDirectory: true)
}

func candidateSecretPaths() -> [URL] {
    [defaultUserDataPath().appendingPathComponent("secrets.json")]
}

private func defaultConfigRoot() -> URL {
    // XDG_CONFIG_HOME → ~/.config
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        return URL(fileURLWithPath: xdg, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
}
