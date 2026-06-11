// Python tests/test_user_paths.py の移植
//
// 移植対象外:
// - test_settings_store_reads_blue_ticker_keychain_value
//   （Swift の SettingsStore は Keystore に静的依存しており、実 Keychain に触れずに検証できないため）

import XCTest
@testable import BlueTicker

final class UserPathsTests: XCTestCase {

    func testDefaultUserDataPathUsesEnv() throws {
        let tmpDir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("custom-blue-ticker", isDirectory: true)

        let original = ProcessInfo.processInfo.environment["BLUE_TICKER_USER_DATA_PATH"]
        setenv("BLUE_TICKER_USER_DATA_PATH", path.path, 1)
        defer {
            if let original {
                setenv("BLUE_TICKER_USER_DATA_PATH", original, 1)
            } else {
                unsetenv("BLUE_TICKER_USER_DATA_PATH")
            }
        }

        XCTAssertEqual(defaultUserDataPath().path, path.path)
    }
}
