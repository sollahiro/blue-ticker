import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// CP932（Windows Shift-JIS）バイト列を UTF-8 文字列へデコードする。
///
/// macOS の `String(data:encoding:.shiftJIS)` は ICU 依存で、Linux の
/// swift-corelibs-foundation には CP932 が無く nil を返す。両OSに常在する
/// system iconv に一本化することで「macOS では読めるが Linux で空になる」差異を防ぐ。
///
/// 不正バイト列（EILSEQ）・不完全な末尾シーケンス（EINVAL）・iconv 初期化失敗時は nil を返す。
func decodeCP932(_ data: Data) -> String? {
    if data.isEmpty { return "" }

    let cd = iconv_open("UTF-8", "CP932")
    if cd == iconv_t(bitPattern: -1) { return nil }
    defer { iconv_close(cd) }

    var output = [UInt8]()
    output.reserveCapacity(data.count * 2)

    let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return true }
        var inPtr: UnsafeMutablePointer<CChar>? =
            UnsafeMutableRawPointer(mutating: base).assumingMemoryBound(to: CChar.self)
        var inLeft = raw.count

        let bufSize = 1 << 16
        var buf = [CChar](repeating: 0, count: bufSize)

        while inLeft > 0 {
            let inBefore = inLeft
            var failure: Int32 = 0
            let produced: Int = buf.withUnsafeMutableBufferPointer { outBuf in
                var outPtr: UnsafeMutablePointer<CChar>? = outBuf.baseAddress!
                var outLeft = bufSize
                let res = iconv(cd, &inPtr, &inLeft, &outPtr, &outLeft)
                if res == -1 { failure = errno }
                return bufSize - outLeft
            }

            if produced > 0 {
                buf.withUnsafeBufferPointer { p in
                    for i in 0..<produced { output.append(UInt8(bitPattern: p[i])) }
                }
            }

            if failure != 0 {
                // E2BIG: 出力バッファが満杯 → 排出済みなのでループ継続して残りを変換
                if failure == E2BIG { continue }
                // EILSEQ（不正バイト）/ EINVAL（末尾の不完全シーケンス）→ 変換失敗
                return false
            }

            // 防御的ガード: iconv が成功扱いで返りつつ入力も出力も進まない理論上の停滞を打ち切る
            if inLeft == inBefore && produced == 0 { return false }
        }
        return true
    }

    guard ok else { return nil }
    return String(decoding: output, as: UTF8.self)
}
