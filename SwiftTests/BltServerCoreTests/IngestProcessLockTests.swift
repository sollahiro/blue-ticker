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

    @Test func waitsUntilReleased() async throws {
        let env = environment(wait: "5")
        let first = try acquireIngestLock(environment: env)
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            first.release()
        }
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
