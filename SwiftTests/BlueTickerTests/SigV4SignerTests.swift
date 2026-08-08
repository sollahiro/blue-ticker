// SigV4Signerのユニットテスト。既知の鍵・固定日時で手計算（Python hashlib/hmac、標準ライブラリのみ・
// ネットワーク不要）した期待値と照合し、AWS Signature V4アルゴリズムの実装が正しいことを保証する。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct SigV4SignerTests {

    private static let fixedDate = Date(timeIntervalSince1970: 1_440_938_160) // 2015-08-30T12:36:00Z

    @Test func signsPutRequestMatchingKnownVector() {
        let signed = SigV4Signer.sign(
            method: "PUT",
            host: "test-account.r2.cloudflarestorage.com",
            path: "/test-bucket/company-icons/1234.png",
            contentType: "image/png",
            payload: Data("hello world".utf8),
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "auto",
            service: "s3",
            date: Self.fixedDate
        )

        #expect(signed.amzDate == "20150830T123600Z")
        #expect(signed.payloadHash == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        #expect(
            signed.authorization
                == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20150830/auto/s3/aws4_request, "
                    + "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, "
                    + "Signature=e3e4b44b431c5cdf6011bc1865c5a4eeaa878540f0c6a93b700ec575a2831a22"
        )
    }

    @Test func signatureChangesWhenPayloadDiffers() {
        func signature(for payload: Data) -> String {
            SigV4Signer.sign(
                method: "PUT", host: "h", path: "/b/k", contentType: "image/png", payload: payload,
                accessKeyID: "AKID", secretAccessKey: "SECRET", region: "auto", service: "s3",
                date: Self.fixedDate
            ).authorization
        }
        #expect(signature(for: Data("a".utf8)) != signature(for: Data("b".utf8)))
    }

    // MARK: - パスのURIエンコード

    @Test func uriEncodePathPreservesSlashesAndUnreservedCharacters() {
        #expect(
            SigV4Signer.uriEncodePath("/bucket/company-icons/1234-A.png")
                == "/bucket/company-icons/1234-A.png"
        )
    }

    @Test func uriEncodePathPercentEncodesReservedCharacters() {
        #expect(SigV4Signer.uriEncodePath("/bucket/icons/foo bar.png") == "/bucket/icons/foo%20bar.png")
    }
}
