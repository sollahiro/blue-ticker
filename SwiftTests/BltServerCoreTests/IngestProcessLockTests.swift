// blt-ingest の排他ロック（定例と手動の同時書き込みを防ぐ）。

import Foundation
import Testing

@testable import BltIngestCore

@Suite struct IngestProcessLockTests {
    private func environment(wait: String? = nil) -> [String: String] {
        let path = NSTemporaryDirectory() + "blt-ingest-lock-test-\(UUID().uuidString).lock"
        var env = ["BLT_INGEST_LOCK_FILE": path]
        if let wait { env["BLT_INGEST_LOCK_WAIT_SEC"] = wait }
        return env
    }

    @Test func secondAcquireFailsWhileHeld() throws {
        let env = environment()
        let first = try acquireIngestLock(environment: env)
        #expect(throws: IngestLockError.self) {
            _ = try acquireIngestLock(environment: env)
        }
        first.release()
    }

    @Test func releaseAllowsNextAcquire() throws {
        let env = environment()
        let first = try acquireIngestLock(environment: env)
        first.release()
        let second = try acquireIngestLock(environment: env)
        second.release()
    }

    @Test func waitsUntilReleased() throws {
        let env = environment(wait: "30")
        let first = try acquireIngestLock(environment: env)
        // 協調スレッドプールを使わない。テストを並列で回すと、待つ側がスレッドを塞いで
        // 解放側のタスクが動けなくなる。
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { first.release() }
        let second = try acquireIngestLock(environment: env)
        second.release()
    }

    @Test func onlyWriteCommandsNeedLock() {
        #expect(ingestCommandNeedsLock(["blt-ingest", "ingest"]))
        #expect(ingestCommandNeedsLock(["blt-ingest", "sync"]))
        #expect(ingestCommandNeedsLock(["blt-ingest", "migrate"]))
        #expect(ingestCommandNeedsLock(["blt-ingest", "overrides", "add"]))
        #expect(ingestCommandNeedsLock(["blt-ingest", "overrides", "revoke"]))
        #expect(!ingestCommandNeedsLock(["blt-ingest", "overrides", "list"]))
        #expect(!ingestCommandNeedsLock(["blt-ingest"]))
        #expect(!ingestCommandNeedsLock(["blt-ingest", "unknown"]))
    }
}
