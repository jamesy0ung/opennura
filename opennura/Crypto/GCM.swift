import Foundation

// MARK: - GCM (explicit J0, matches nura_crypto.py)

struct U128 {
    var hi: UInt64
    var lo: UInt64
    init(_ hi: UInt64, _ lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }
    init(bytes: [UInt8]) {
        hi = bytes[0..<8].reduce(0) { ($0 << 8) | UInt64($1) }
        lo = bytes[8..<16].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    func toBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            out[i] = UInt8((hi >> (8 * (7 - i))) & 0xFF)
            out[8 + i] = UInt8((lo >> (8 * (7 - i))) & 0xFF)
        }
        return out
    }
    static func ^ (a: U128, b: U128) -> U128 { U128(a.hi ^ b.hi, a.lo ^ b.lo) }
    func bit(_ i: Int) -> Bool {
        i < 64 ? (hi >> (63 - i)) & 1 == 1 : (lo >> (127 - i)) & 1 == 1
    }
    var lsb: Bool { lo & 1 == 1 }
    func shiftedRight1() -> U128 { U128(hi >> 1, (lo >> 1) | ((hi & 1) << 63)) }
}

private let ghashR = U128(0xE100_0000_0000_0000, 0)

private func gfMult(_ x: U128, _ y: U128) -> U128 {
    var z = U128(0, 0)
    var v = y
    for i in 0..<128 {
        if x.bit(i) { z = z ^ v }
        v = v.lsb ? (v.shiftedRight1() ^ ghashR) : v.shiftedRight1()
    }
    return z
}

private func ghash(h: U128, data: [UInt8]) -> U128 {
    var y = U128(0, 0)
    var i = 0
    while i < data.count {
        var block = Array(data[i..<min(i + 16, data.count)])
        if block.count < 16 {
            block += [UInt8](repeating: 0, count: 16 - block.count)
        }
        y = gfMult(y ^ U128(bytes: block), h)
        i += 16
    }
    return y
}

private func inc32(_ block: [UInt8]) -> [UInt8] {
    var out = block
    var ctr =
        (UInt32(out[12]) << 24) | (UInt32(out[13]) << 16)
        | (UInt32(out[14]) << 8) | UInt32(out[15])
    ctr = ctr &+ 1
    out[12] = UInt8((ctr >> 24) & 0xFF)
    out[13] = UInt8((ctr >> 16) & 0xFF)
    out[14] = UInt8((ctr >> 8) & 0xFF)
    out[15] = UInt8(ctr & 0xFF)
    return out
}

private func aesCtr(key: [UInt8], icb: [UInt8], data: [UInt8]) -> [UInt8] {
    guard !data.isEmpty else { return [] }
    let aes = AES128(key: key)
    var out = [UInt8](repeating: 0, count: data.count)
    var ctr = icb
    var off = 0
    while off < data.count {
        let ks = aes.encryptBlock(ctr)
        let n = min(16, data.count - off)
        for i in 0..<n { out[off + i] = data[off + i] ^ ks[i] }
        ctr = inc32(ctr)
        off += n
    }
    return out
}

enum GCMError: Error { case tagMismatch }

func gcmWithJ0(key: [UInt8], j0: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> (
    ct: [UInt8], tag: [UInt8]
) {
    let aes = AES128(key: key)
    let h = U128(bytes: aes.encryptBlock([UInt8](repeating: 0, count: 16)))
    let ct = aesCtr(key: key, icb: inc32(j0), data: plaintext)
    var s = aad
    if aad.count % 16 != 0 {
        s += [UInt8](repeating: 0, count: 16 - (aad.count % 16))
    }
    s += ct
    if ct.count % 16 != 0 {
        s += [UInt8](repeating: 0, count: 16 - (ct.count % 16))
    }
    s += withUnsafeBytes(of: (UInt64(aad.count) * 8).bigEndian) { Array($0) }
    s += withUnsafeBytes(of: (UInt64(ct.count) * 8).bigEndian) { Array($0) }
    let tag = (ghash(h: h, data: s) ^ U128(bytes: aes.encryptBlock(j0)))
        .toBytes()
    return (ct, tag)
}

func gcmOpenJ0(
    key: [UInt8],
    j0: [UInt8],
    aad: [UInt8],
    ciphertext: [UInt8],
    tag: [UInt8]
) throws -> [UInt8] {
    let aes = AES128(key: key)
    let h = U128(bytes: aes.encryptBlock([UInt8](repeating: 0, count: 16)))
    var s = aad
    if aad.count % 16 != 0 {
        s += [UInt8](repeating: 0, count: 16 - (aad.count % 16))
    }
    s += ciphertext
    if ciphertext.count % 16 != 0 {
        s += [UInt8](repeating: 0, count: 16 - (ciphertext.count % 16))
    }
    s += withUnsafeBytes(of: (UInt64(aad.count) * 8).bigEndian) { Array($0) }
    s += withUnsafeBytes(of: (UInt64(ciphertext.count) * 8).bigEndian) {
        Array($0)
    }
    let expected = (ghash(h: h, data: s) ^ U128(bytes: aes.encryptBlock(j0)))
        .toBytes()
    guard expected == tag else { throw GCMError.tagMismatch }
    return aesCtr(key: key, icb: inc32(j0), data: ciphertext)
}
