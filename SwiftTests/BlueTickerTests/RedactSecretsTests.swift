import Foundation
import Testing

@testable import BlueTickerCore

@Suite struct RedactSecretsTests {
    @Test func masksPostgresPassword() {
        let raw = "SQLPostgresConfiguration failed: postgres://blt:hunter2@ep-foo.neon.tech/db"
        let redacted = redactSecrets(raw)
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("postgres://blt:***@ep-foo.neon.tech/db"))
    }

    @Test func masksPostgresqlSchemeAndSubscriptionKeyAndBearer() {
        let raw =
            "postgresql://u:secretpass@host/db Subscription-Key=abc123 Bearer tok_secret rest"
        let redacted = redactSecrets(raw)
        #expect(!redacted.contains("secretpass"))
        #expect(!redacted.contains("abc123"))
        #expect(!redacted.contains("tok_secret"))
        #expect(redacted.contains("postgresql://u:***@host/db"))
        #expect(redacted.contains("Subscription-Key=***"))
        #expect(redacted.contains("Bearer ***"))
    }

    @Test func leavesOrdinaryMessagesUnchanged() {
        #expect(redactSecrets("ingest summary failed=0") == "ingest summary failed=0")
    }
}
