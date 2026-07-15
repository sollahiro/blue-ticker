// Python tests/test_user_paths.py の移植

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct UserPathsTests {

    @Test func testDefaultUserDataPathUsesEnv() throws {
        let tmpDir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("custom-blue-ticker", isDirectory: true)

        let environment = ["BLUE_TICKER_USER_DATA_PATH": path.path]
        #expect(defaultUserDataPath(environment: environment).path == path.path)
    }
}
