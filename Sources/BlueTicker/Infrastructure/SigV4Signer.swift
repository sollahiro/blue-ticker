// AWS Signature Version 4（SigV4）署名の最小実装。R2Client（Cloudflare R2）専用。
// R2 は S3 互換 API のみを公開し AWS SDK は存在しないため、単一ヘッダー・単一署名対象
// （PUT オブジェクト、クエリ文字列なし）に絞って自前実装する。汎用 SigV4（マルチパート・
// 事前署名URL等）はサポートしない。

import Crypto
import Foundation

enum SigV4Signer {

    struct SignedHeaders: Sendable {
        let amzDate: String
        let payloadHash: String
        let authorization: String
    }

    /// `PUT https://{host}{path}` を SigV4 署名する（クエリ文字列なし、ヘッダーは
    /// content-type/host/x-amz-content-sha256/x-amz-date の4つに固定）。
    static func sign(
        method: String,
        host: String,
        path: String,
        contentType: String,
        payload: Data,
        accessKeyID: String,
        secretAccessKey: String,
        region: String,
        service: String,
        date: Date = Date()
    ) -> SignedHeaders {
        let amzDate = amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = sha256Hex(payload)

        let canonicalHeaders =
            "content-type:\(contentType)\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaderNames = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            method, uriEncodePath(path), "", canonicalHeaders, signedHeaderNames, payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, credentialScope, sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secretAccessKey: secretAccessKey, dateStamp: dateStamp, region: region, service: service
        )
        let signature = hmacHex(key: signingKey, message: Data(stringToSign.utf8))

        let authorization =
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaderNames), Signature=\(signature)"

        return SignedHeaders(amzDate: amzDate, payloadHash: payloadHash, authorization: authorization)
    }

    // MARK: - 正規化・ハッシュ

    /// AWS の URI エンコード規則: 非予約文字（英数字・`-` `.` `_` `~`）以外を UTF-8 バイト単位で
    /// `%XX`（大文字16進）に変換する。`/` はパス区切りとして温存し、セグメント単位でエンコードする。
    static func uriEncodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncodeSegment(String($0)) }
            .joined(separator: "/")
    }

    private static func uriEncodeSegment(_ segment: String) -> String {
        var result = ""
        for byte in Array(segment.utf8) {
            if isUnreservedByte(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func isUnreservedByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
            UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func hmacHex(key: Data, message: Data) -> String {
        hmac(key: key, message: message).map { String(format: "%02x", $0) }.joined()
    }

    private static func deriveSigningKey(
        secretAccessKey: String, dateStamp: String, region: String, service: String
    ) -> Data {
        let kSecret = Data("AWS4\(secretAccessKey)".utf8)
        let kDate = hmac(key: kSecret, message: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, message: Data(region.utf8))
        let kService = hmac(key: kRegion, message: Data(service.utf8))
        return hmac(key: kService, message: Data("aws4_request".utf8))
    }
}

private let amzDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()
