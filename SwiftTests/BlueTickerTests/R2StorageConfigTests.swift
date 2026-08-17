// R2 生 XBRL L2 の設定・キー規則。ネットワーク不要。

import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct R2StorageConfigTests {
    private let creds: [String: String] = [
        "BLT_R2_ACCOUNT_ID": "acct",
        "BLT_R2_ACCESS_KEY_ID": "key",
        "BLT_R2_SECRET_ACCESS_KEY": "secret",
    ]

    @Test func xbrlResolvesFromDedicatedBucketWithoutPublicURL() {
        var env = creds
        env["BLT_R2_XBRL_BUCKET"] = "xbrl-private"
        let storage = R2StorageConfig.resolveXbrlFromEnvironment(env)
        #expect(storage?.bucket == "xbrl-private")
        #expect(storage?.endpointHost == "acct.r2.cloudflarestorage.com")
        #expect(R2Config.resolveFromEnvironment(env) == nil)
        #expect(R2StorageConfig.resolveIconsFromEnvironment(env) == nil)
    }

    @Test func xbrlDoesNotFallBackToIconBucket() {
        var env = creds
        env["BLT_R2_ICONS_BUCKET"] = "icons-public"
        env["BLT_R2_BUCKET"] = "legacy-icons"
        #expect(R2StorageConfig.resolveXbrlFromEnvironment(env) == nil)
    }

    @Test func iconsPreferDedicatedBucketOverLegacy() {
        var env = creds
        env["BLT_R2_ICONS_BUCKET"] = "icons-public"
        env["BLT_R2_BUCKET"] = "legacy-icons"
        env["BLT_R2_PUBLIC_BASE_URL"] = "https://icons.example.com"
        #expect(R2StorageConfig.resolveIconsFromEnvironment(env)?.bucket == "icons-public")
        #expect(R2Config.resolveFromEnvironment(env)?.bucket == "icons-public")
    }

    @Test func iconsFallBackToLegacyBucketName() {
        var env = creds
        env["BLT_R2_BUCKET"] = "legacy-icons"
        env["BLT_R2_PUBLIC_BASE_URL"] = "https://icons.example.com"
        #expect(R2Config.resolveFromEnvironment(env)?.bucket == "legacy-icons")
        #expect(R2StorageConfig.resolveXbrlFromEnvironment(env) == nil)
    }

    @Test func nilWhenCredentialsMissing() {
        let env = ["BLT_R2_XBRL_BUCKET": "xbrl-private"]
        #expect(R2StorageConfig.resolveXbrlFromEnvironment(env) == nil)
        #expect(R2StorageConfig.resolveIconsFromEnvironment(env) == nil)
    }

    @Test func xbrlObjectKeyUsesRegionSourcePrefix() {
        #expect(xbrlR2ObjectKey(docID: "S100TEST") == "jp/edinet/xbrl/S100TEST.zip")
        #expect(xbrlR2ObjectKey(docID: "") == nil)
        #expect(xbrlR2ObjectKey(docID: "S100/../x") == nil)
        #expect(xbrlR2ObjectKey(docID: "S100 TEST") == nil)
    }
}
