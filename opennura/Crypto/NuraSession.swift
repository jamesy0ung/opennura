import Foundation

// MARK: - Nura session counters (spec §4.3)

let kyleAAD: [UInt8] = Array("Kyle is awesome!".utf8)

func makeJ0(nonce: [UInt8], counter: UInt32, deviceToApp: Bool) -> [UInt8] {
    let c: UInt32 = counter | (deviceToApp ? 0x8000_0000 : 0)
    return nonce + [
        UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF),
        UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF),
    ]
}

func advanceCounter(_ counter: UInt32, plainLen: Int) -> UInt32 {
    counter + 1 + UInt32(plainLen / 16)
}

final class NuraSession {
    let key: [UInt8]
    let nonce: [UInt8]
    var encCtr: UInt32 = 2
    var decCtr: UInt32 = 2
    init(key: [UInt8], nonce: [UInt8]) {
        self.key = key
        self.nonce = nonce
    }

    func decryptDevToApp(_ payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 16 else {
            throw NuraError.malformed("dev->app payload too short")
        }
        let tag = Array(payload[0..<16])
        let ct = Array(payload[16...])
        let j0 = makeJ0(nonce: nonce, counter: decCtr, deviceToApp: true)
        let pt = try gcmOpenJ0(
            key: key,
            j0: j0,
            aad: [],
            ciphertext: ct,
            tag: tag
        )
        decCtr = advanceCounter(decCtr, plainLen: pt.count)
        return pt
    }

    func encryptAppToDev(_ plaintext: [UInt8]) -> (tag: [UInt8], ct: [UInt8]) {
        let j0 = makeJ0(nonce: nonce, counter: encCtr, deviceToApp: false)
        let (ct, tag) = gcmWithJ0(
            key: key,
            j0: j0,
            aad: [],
            plaintext: plaintext
        )
        encCtr = advanceCounter(encCtr, plainLen: plaintext.count)
        return (tag, ct)
    }
}
