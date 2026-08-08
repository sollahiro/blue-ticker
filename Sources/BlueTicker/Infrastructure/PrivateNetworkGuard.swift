// 会社が開示した任意URL（電子公告URL等）へサーバーサイドでHTTPアクセスするための SSRF ガード。
// ホスト名をDNS解決し、解決先アドレスが1つでもprivate/loopback/link-local/reserved なら拒否する。
// DNS rebinding（チェック後に別アドレスへ再解決される攻撃）は完全には防げない
// （TOCTOU）が、既知の約3,800社のEDINET開示ドメインのみを対象とする低リスク用途のため、
// 接続前チェック＋リダイレクト先チェックの二段構えで実用上十分な防御とする。

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum PrivateNetworkGuard {

    /// ホスト名がpublicなら true。DNS解決失敗時・解決先が1つも取れない場合も false（拒否側に倒す）。
    static func isPublicHost(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &resultPointer)
        guard status == 0, let first = resultPointer else { return false }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var sawAddress = false
        while let node = current {
            sawAddress = true
            if let addr = node.pointee.ai_addr {
                if node.pointee.ai_family == AF_INET {
                    let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let octets = withUnsafeBytes(of: sin.sin_addr) { Array($0) }
                    if isPrivateIPv4(octets) { return false }
                } else if node.pointee.ai_family == AF_INET6 {
                    let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                    if isPrivateIPv6(bytes) { return false }
                }
            }
            current = node.pointee.ai_next
        }
        return sawAddress
    }

    private static func isPrivateIPv4(_ o: [UInt8]) -> Bool {
        guard o.count == 4 else { return true }  // 想定外の長さは安全側で拒否
        if o[0] == 0 { return true }                                  // "this network"
        if o[0] == 10 { return true }                                 // 10.0.0.0/8
        if o[0] == 127 { return true }                                // loopback
        if o[0] == 169, o[1] == 254 { return true }                   // link-local
        if o[0] == 172, (16...31).contains(o[1]) { return true }      // 172.16.0.0/12
        if o[0] == 192, o[1] == 168 { return true }                   // 192.168.0.0/16
        if o[0] == 100, (64...127).contains(o[1]) { return true }     // 100.64.0.0/10 (CGNAT)
        if o[0] >= 224 { return true }                                // multicast/reserved
        return false
    }

    private static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        if b.allSatisfy({ $0 == 0 }) { return true }                          // :: (unspecified)
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }      // ::1 (loopback)
        if b[0] == 0xfc || b[0] == 0xfd { return true }                       // fc00::/7 unique local
        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return true }                // fe80::/10 link-local
        // IPv4射影アドレス ::ffff:a.b.c.d は埋め込みIPv4側で判定する。
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
            return isPrivateIPv4(Array(b[12...15]))
        }
        return false
    }
}
