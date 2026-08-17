// R2 生 XBRL L2 の設定・キー規則。ネットワーク不要。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct R2StorageConfigTests {
    @Test func resolvesWithoutPublicBaseURL() {
        let env = [
            "BLT_R2_ACCOUNT_ID": "acct",
            "BLT_R2_ACCESS_KEY_ID": "key",
            "BLT_R2_SECRET_ACCESS_KEY": "secret",
            "BLT_R2_BUCKET": "bucket",
        ]
        let storage = R2StorageConfig.resolveFromEnvironment(env)
        #expect(storage?.bucket == "bucket")
        #expect(storage?.endpointHost == "acct.r2.cloudflarestorage.com")
        #expect(R2Config.resolveFromEnvironment(env) == nil)
    }

    @Test func iconConfigStillRequiresPublicBaseURL() {
        let env = [
            "BLT_R2_ACCOUNT_ID": "acct",
            "BLT_R2_ACCESS_KEY_ID": "key",
            "BLT_R2_SECRET_ACCESS_KEY": "secret",
            "BLT_R2_BUCKET": "bucket",
            "BLT_R2_PUBLIC_BASE_URL": "https://icons.example.com",
        ]
        #expect(R2Config.resolveFromEnvironment(env) != nil)
        #expect(R2StorageConfig.resolveFromEnvironment(env) != nil)
    }

    @Test func nilWhenBucketMissing() {
        let env = [
            "BLT_R2_ACCOUNT_ID": "acct",
            "BLT_R2_ACCESS_KEY_ID": "key",
            "BLT_R2_SECRET_ACCESS_KEY": "secret",
        ]
        #expect(R2StorageConfig.resolveFromEnvironment(env) == nil)
    }

    @Test func xbrlObjectKeyUsesRegionSourcePrefix() {
        #expect(xbrlR2ObjectKey(docID: "S100TEST") == "jp/edinet/xbrl/S100TEST.zip")
        #expect(xbrlR2ObjectKey(docID: "") == nil)
        #expect(xbrlR2ObjectKey(docID: "S100/../x") == nil)
        #expect(xbrlR2ObjectKey(docID: "S100 TEST") == nil)
    }
}
