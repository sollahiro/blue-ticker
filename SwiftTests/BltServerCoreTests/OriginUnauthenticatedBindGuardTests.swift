// 非 loopback bind の無認証起動ガード。プロセス環境は書き換えない（並列テストと競合するため
// 引数注入。`R2StorageConfigTests` / `registerRoutes` の cfAccessTeamDomain と同じ方針）。

import Foundation
import Testing

@testable import BltServerCore

@Suite struct OriginUnauthenticatedBindGuardTests {

    @Test func loopbackAllowsUnauthenticated() {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "::1", "[::1]", "127.0.0.2"] {
            #expect(
                OriginUnauthenticatedBindGuard.evaluate(
                    host: host, cfAccessTeamDomain: nil, allowUnauthenticated: nil
                ) == .allow)
        }
    }

    @Test func loopbackTrimsWhitespace() {
        #expect(
            OriginUnauthenticatedBindGuard.evaluate(
                host: "  127.0.0.1  ", cfAccessTeamDomain: nil, allowUnauthenticated: nil
            ) == .allow)
    }

    @Test func wildcardAndLanRefuseWithoutOptInOrAccess() {
        for host in ["0.0.0.0", "::", "[::]", "192.168.1.10", "10.0.0.2"] {
            guard case .refuse(let message) = OriginUnauthenticatedBindGuard.evaluate(
                host: host, cfAccessTeamDomain: nil, allowUnauthenticated: nil
            ) else {
                Issue.record("expected refuse for host \(host)")
                continue
            }
            #expect(message.contains("CF_ACCESS_TEAM_DOMAIN"))
            #expect(message.contains("BLT_ALLOW_UNAUTHENTICATED=1"))
            #expect(message.contains(host))
        }
    }

    @Test func emptyHostIsNotLoopback() {
        guard case .refuse = OriginUnauthenticatedBindGuard.evaluate(
            host: "", cfAccessTeamDomain: nil, allowUnauthenticated: nil
        ) else {
            Issue.record("empty host must not be treated as loopback")
            return
        }
    }

    @Test func nonLoopbackAllowsWhenAccessDomainSet() {
        #expect(
            OriginUnauthenticatedBindGuard.evaluate(
                host: "0.0.0.0",
                cfAccessTeamDomain: "example.cloudflareaccess.com",
                allowUnauthenticated: nil
            ) == .allow)
    }

    @Test func whitespaceOnlyAccessDomainDoesNotCount() {
        guard case .refuse = OriginUnauthenticatedBindGuard.evaluate(
            host: "0.0.0.0", cfAccessTeamDomain: "   ", allowUnauthenticated: nil
        ) else {
            Issue.record("whitespace-only CF_ACCESS_TEAM_DOMAIN must not open non-loopback")
            return
        }
    }

    @Test func nonLoopbackAllowsExplicitOptIn() {
        #expect(
            OriginUnauthenticatedBindGuard.evaluate(
                host: "0.0.0.0", cfAccessTeamDomain: nil, allowUnauthenticated: "1"
            ) == .allow)
        #expect(
            OriginUnauthenticatedBindGuard.evaluate(
                host: "0.0.0.0", cfAccessTeamDomain: nil, allowUnauthenticated: " 1 "
            ) == .allow)
    }

    @Test func optInMustBeExactlyOne() {
        for value in ["true", "yes", "TRUE", "0", ""] {
            guard case .refuse = OriginUnauthenticatedBindGuard.evaluate(
                host: "0.0.0.0", cfAccessTeamDomain: nil, allowUnauthenticated: value
            ) else {
                Issue.record("BLT_ALLOW_UNAUTHENTICATED=\(value) must not opt in")
                continue
            }
        }
    }

    @Test func isLoopbackBindLiterals() {
        #expect(OriginUnauthenticatedBindGuard.isLoopbackBind("127.0.0.1"))
        #expect(OriginUnauthenticatedBindGuard.isLoopbackBind("localhost"))
        #expect(!OriginUnauthenticatedBindGuard.isLoopbackBind("0.0.0.0"))
        #expect(!OriginUnauthenticatedBindGuard.isLoopbackBind("::"))
        #expect(!OriginUnauthenticatedBindGuard.isLoopbackBind("192.168.0.1"))
    }
}
