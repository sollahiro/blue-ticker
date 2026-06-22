import Foundation
import Testing
@testable import BlueTickerCore

@Suite struct CP932DecoderTests {

    @Test func emptyDataReturnsEmptyString() {
        #expect(decodeCP932(Data()) == "")
    }

    @Test func decodesKanjiFromCP932Bytes() {
        // 日=0x93FA 立=0x97A7（CP932）
        let bytes: [UInt8] = [0x93, 0xFA, 0x97, 0xA7]
        #expect(decodeCP932(Data(bytes)) == "日立")
    }

    @Test func decodesHalfWidthKatakana() {
        // ｱ=0xB1 ｲ=0xB2（CP932 単バイト半角カナ）
        let bytes: [UInt8] = [0xB1, 0xB2]
        #expect(decodeCP932(Data(bytes)) == "ｱｲ")
    }

    @Test func decodesNecIbmExtensionCharacter() {
        // ① 丸数字（NEC特殊文字 0x8740）— SHIFT_JIS では変換不可、CP932 でのみ通る
        let bytes: [UInt8] = [0x87, 0x40]
        #expect(decodeCP932(Data(bytes)) == "①")
    }

    @Test func invalidLeadByteReturnsNil() {
        // 0x93（漢字の先行バイト）単独 → 不完全シーケンス（EINVAL）→ nil
        #expect(decodeCP932(Data([0x93])) == nil)
    }

    @Test func largeInputSpanningOutputBufferDecodesFully() {
        // 64KB 出力バッファ（あ=UTF-8 3バイト）を跨ぐ大きな入力で E2BIG パスを検証
        let count = 50_000
        let bytes = [UInt8](repeating: 0, count: count * 2).enumerated().map { idx, _ in
            idx % 2 == 0 ? UInt8(0x82) : UInt8(0xA0)  // あ=0x82A0 を count 回
        }
        let decoded = decodeCP932(Data(bytes))
        #expect(decoded?.count == count)
        #expect(decoded == String(repeating: "あ", count: count))
    }
}
