// blt-ingest の同時実行を防ぐ排他ロック（取り込み Mac 上のプロセス間）。
//
// 定例（launchd）と手動の `--codes` が同時に本番へ書くと、同じ行を取り合う。ロックは
// `flock`（アドバイザリ）で、プロセスが終了するとき（異常終了を含む）に OS が解放するので、
// 古いロックファイルが残って次の実行を止めることはない。
// 既定のロックファイルは `/tmp/blt-ingest-<uid>.lock`（`BLT_INGEST_LOCK_FILE` で変更）。
// 別のプロセスが保持中は、既定ですぐに失敗する。`BLT_INGEST_LOCK_WAIT_SEC` に秒数を指定すると、
// その時間まで待つ（1 秒間隔で再試行）。
// 対象は書き込みを伴うコマンド（migrate / sync / ingest / master-data-upload / screen-rebuild /
// overrides add|revoke）。read 専用のコマンドは対象外。

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum IngestLockError: Error, CustomStringConvertible {
    case heldByAnotherProcess(path: String, waitedSeconds: Int)
    case cannotOpen(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .heldByAnotherProcess(let path, let waited):
            let suffix = waited > 0 ? "（\(waited) 秒待ちました）" : ""
            return "別の blt-ingest が実行中です。\(path) を保持しているプロセスの終了後に再実行してください\(suffix)"
        case .cannotOpen(let path, let code):
            return "ロックファイルを開けません: \(path)（errno=\(code)）"
        }
    }
}

/// 取得したロック。解放はプロセス終了時（または `release()`）。
public final class IngestProcessLock: @unchecked Sendable {
    private var fd: Int32

    fileprivate init(fd: Int32) { self.fd = fd }

    public func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// 書き込みを伴うコマンドか。`argv` は `CommandLine.arguments` 相当。
public func ingestCommandNeedsLock(_ argv: [String]) -> Bool {
    guard argv.count > 1 else { return false }
    switch argv[1] {
    case "migrate", "sync", "ingest", "master-data-upload", "screen-rebuild":
        return true
    case "overrides":
        return argv.count > 2 && (argv[2] == "add" || argv[2] == "revoke")
    default:
        return false
    }
}

public func defaultIngestLockPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    if let custom = environment["BLT_INGEST_LOCK_FILE"], !custom.isEmpty { return custom }
    return "/tmp/blt-ingest-\(getuid()).lock"
}

/// ロックを取る。取れなければ `IngestLockError` を投げる。
public func acquireIngestLock(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> IngestProcessLock {
    let path = defaultIngestLockPath(environment: environment)
    let waitSeconds = max(0, Int(environment["BLT_INGEST_LOCK_WAIT_SEC"] ?? "") ?? 0)
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw IngestLockError.cannotOpen(path: path, errno: errno) }
    var waited = 0
    while true {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return IngestProcessLock(fd: fd) }
        let code = errno
        guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
            close(fd)
            throw IngestLockError.cannotOpen(path: path, errno: code)
        }
        if waited >= waitSeconds {
            close(fd)
            throw IngestLockError.heldByAnotherProcess(path: path, waitedSeconds: waited)
        }
        sleep(1)
        waited += 1
    }
}
