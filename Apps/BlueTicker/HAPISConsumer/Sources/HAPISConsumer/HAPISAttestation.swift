import Foundation

/// 将来の App Attest（`DCAppAttestService`）用の薄いフック。この PR では stub のみ。
/// `ATTEST_MODE=enforce` の本番 Attest は未配線。緊急トークンも出さない。
protocol HAPISAttestationProviding: Sendable {
    func payloadForMint() async throws -> HAPISAttestationPayload?
}

struct HAPISAttestationPayload: Encodable, Equatable, Sendable {
    var keyId: String?

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
    }
}

/// `ATTEST_MODE=stub`。challenge は送らず、mint ボディは `{}`。
struct HAPISStubAttestationProvider: HAPISAttestationProviding {
    func payloadForMint() async throws -> HAPISAttestationPayload? {
        nil
    }
}
