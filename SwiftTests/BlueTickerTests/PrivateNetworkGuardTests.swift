// PrivateNetworkGuardのユニットテスト。SSRFガードの中核（private/loopback/link-local判定）。
// リテラルIPアドレスはgetaddrinfoがネットワークに出ずローカルで解決するため、実ネットワークに
// 依存せず決定的に緑になる。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct PrivateNetworkGuardTests {

    @Test func rejectsLoopbackIPv4() {
        #expect(PrivateNetworkGuard.isPublicHost("127.0.0.1") == false)
    }

    @Test func rejectsLoopbackIPv6() {
        #expect(PrivateNetworkGuard.isPublicHost("::1") == false)
    }

    @Test func rejectsRFC1918PrivateRanges() {
        #expect(PrivateNetworkGuard.isPublicHost("10.0.0.1") == false)
        #expect(PrivateNetworkGuard.isPublicHost("172.16.0.1") == false)
        #expect(PrivateNetworkGuard.isPublicHost("172.31.255.255") == false)
        #expect(PrivateNetworkGuard.isPublicHost("192.168.1.1") == false)
    }

    @Test func rejectsLinkLocalIPv4() {
        #expect(PrivateNetworkGuard.isPublicHost("169.254.1.1") == false)
    }

    @Test func rejectsLinkLocalIPv6() {
        #expect(PrivateNetworkGuard.isPublicHost("fe80::1") == false)
    }

    @Test func rejectsUniqueLocalIPv6() {
        #expect(PrivateNetworkGuard.isPublicHost("fd00::1") == false)
    }

    @Test func doesNotRejectAdjacentPublicIPv4Boundaries() {
        // 172.15.x.x / 172.32.x.x は 172.16.0.0/12 の範囲外（private判定に含めてはならない境界確認）。
        #expect(PrivateNetworkGuard.isPublicHost("172.15.255.255") == true)
        #expect(PrivateNetworkGuard.isPublicHost("172.32.0.0") == true)
    }

    @Test func rejectsUnresolvableHost() {
        #expect(PrivateNetworkGuard.isPublicHost("this-host-does-not-exist.invalid") == false)
    }
}
