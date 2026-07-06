// CloudflaredAccess.fetchToken() の振る舞い検証。
// `cloudflared` の代わりに /bin/sh スタブスクリプトを実行させ、外部バイナリなしで検証する。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct CloudflaredAccessTests {

    /// 指定内容の実行可能な /bin/sh スクリプトを一時ディレクトリへ作成し、パスを返す。
    private static func makeStubScript(_ dir: URL, name: String = "stub.sh", body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func fetchTokenReturnsSuccessWithTrimmedTokenWhenExitZero() throws {
        let tmpDir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let stub = try Self.makeStubScript(
            tmpDir,
            body: """
            #!/bin/sh
            printf '  eyJhbGciOiJSUzI1NiJ9.stub.token  \\n'
            exit 0
            """)

        let result = CloudflaredAccess.fetchToken(appURL: "https://example.com", binaryPathOverride: stub)

        guard case .success(let token) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(token == "eyJhbGciOiJSUzI1NiJ9.stub.token")
    }

    @Test func fetchTokenReturnsProcessFailedWithStderrWhenExitNonZero() throws {
        let tmpDir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let stub = try Self.makeStubScript(
            tmpDir,
            body: """
            #!/bin/sh
            echo 'no valid session found, please run: cloudflared access login' 1>&2
            exit 1
            """)

        let result = CloudflaredAccess.fetchToken(appURL: "https://example.com", binaryPathOverride: stub)

        guard case .processFailed(let exitCode, let stderr) = result else {
            Issue.record("expected .processFailed, got \(result)")
            return
        }
        #expect(exitCode == 1)
        #expect(stderr.contains("no valid session found"))
    }

    /// issue #33 の典型ケース: トークン未保存時の cloudflared は exit 0・stdout 空で
    /// stderr に理由を出す。この stderr が診断として拾われることを検証する。
    @Test func fetchTokenReturnsEmptyTokenWithStderrWhenExitZeroAndStdoutBlank() throws {
        let tmpDir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let stub = try Self.makeStubScript(
            tmpDir,
            body: """
            #!/bin/sh
            echo 'Unable to find token for provided application. Please run login command to generate token.' 1>&2
            exit 0
            """)

        let result = CloudflaredAccess.fetchToken(appURL: "https://example.com", binaryPathOverride: stub)

        guard case .emptyToken(let stderr) = result else {
            Issue.record("expected .emptyToken, got \(result)")
            return
        }
        #expect(stderr.contains("Unable to find token for provided application"))
    }

    @Test func fetchTokenReturnsEmptyTokenWithBlankStderrWhenNoOutputAtAll() throws {
        let tmpDir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let stub = try Self.makeStubScript(
            tmpDir,
            body: """
            #!/bin/sh
            exit 0
            """)

        let result = CloudflaredAccess.fetchToken(appURL: "https://example.com", binaryPathOverride: stub)

        guard case .emptyToken(let stderr) = result else {
            Issue.record("expected .emptyToken, got \(result)")
            return
        }
        #expect(stderr.isEmpty)
    }

    /// 回帰テスト: stderr がパイプバッファ上限（通常 64KB）を大幅に超えても、
    /// 子プロセスの書き込みブロックによるデッドロックを起こさず結果を返す。
    @Test func fetchTokenDoesNotDeadlockWhenStderrExceedsPipeBufferSize() throws {
        let tmpDir = try ServiceTestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // 64KB を大きく超える 200,000 バイト強を stderr へ書き込む。
        let stub = try Self.makeStubScript(
            tmpDir,
            body: """
            #!/bin/sh
            i=0
            while [ $i -lt 2000 ]; do
                printf '%0100d' 0 1>&2
                i=$((i + 1))
            done
            printf 'eyJhbGciOiJSUzI1NiJ9.big-stderr.token'
            exit 0
            """)

        let result = CloudflaredAccess.fetchToken(appURL: "https://example.com", binaryPathOverride: stub)

        guard case .success(let token) = result else {
            Issue.record("expected .success (no deadlock), got \(result)")
            return
        }
        #expect(token == "eyJhbGciOiJSUzI1NiJ9.big-stderr.token")
    }

    @Test func fetchTokenReturnsProcessFailedWhenBinaryPathDoesNotExist() {
        let missingPath = "/nonexistent/path/to/cloudflared-\(UUID().uuidString)"

        let result = CloudflaredAccess.fetchToken(appURL: "https://example.com", binaryPathOverride: missingPath)

        guard case .processFailed = result else {
            Issue.record("expected .processFailed for missing binary, got \(result)")
            return
        }
    }
}
