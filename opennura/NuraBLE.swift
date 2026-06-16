import Combine
import CoreBluetooth
import Foundation

// MARK: - AES-128 (encryption only; GCM decryption also uses AES-encrypt for CTR keystream)

private let aesSbox: [UInt8] = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
    0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf,
    0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1,
    0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3,
    0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39,
    0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
    0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21,
    0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d,
    0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
    0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62,
    0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea,
    0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
    0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9,
    0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9,
    0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
    0xb0, 0x54, 0xbb, 0x16,
]
private let aesRcon: [UInt8] = [
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
]

private struct AES128 {
    private let roundKeys: [[UInt8]]

    init(key: [UInt8]) {
        var w = [[UInt8]](repeating: [0, 0, 0, 0], count: 44)
        for i in 0..<4 {
            w[i] = [key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]
        }
        for i in 4..<44 {
            var t = w[i - 1]
            if i % 4 == 0 {
                t = [t[1], t[2], t[3], t[0]]
                t = t.map { aesSbox[Int($0)] }
                t[0] ^= aesRcon[i / 4 - 1]
            }
            w[i] = [
                w[i - 4][0] ^ t[0], w[i - 4][1] ^ t[1], w[i - 4][2] ^ t[2],
                w[i - 4][3] ^ t[3],
            ]
        }
        var rks: [[UInt8]] = []
        for r in 0..<11 {
            var rk: [UInt8] = []
            for c in 0..<4 { rk += w[r * 4 + c] }
            rks.append(rk)
        }
        roundKeys = rks
    }

    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        var s = input
        for i in 0..<16 { s[i] ^= roundKeys[0][i] }
        for round in 1...9 {
            s = AES128.subBytes(s)
            s = AES128.shiftRows(s)
            s = AES128.mixColumns(s)
            for i in 0..<16 { s[i] ^= roundKeys[round][i] }
        }
        s = AES128.subBytes(s)
        s = AES128.shiftRows(s)
        for i in 0..<16 { s[i] ^= roundKeys[10][i] }
        return s
    }

    private static func gmul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a
        var b = b
        var p: UInt8 = 0
        for _ in 0..<8 {
            if b & 1 != 0 { p ^= a }
            let hi = a & 0x80 != 0
            a = a << 1
            if hi { a ^= 0x1b }
            b >>= 1
        }
        return p
    }
    private static func subBytes(_ s: [UInt8]) -> [UInt8] {
        s.map { aesSbox[Int($0)] }
    }
    private static func shiftRows(_ s: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for row in 0..<4 {
            for col in 0..<4 {
                out[row + 4 * col] = s[row + 4 * ((col + row) % 4)]
            }
        }
        return out
    }
    private static func mixColumns(_ s: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for c in 0..<4 {
            let a0 = s[4 * c]
            let a1 = s[4 * c + 1]
            let a2 = s[4 * c + 2]
            let a3 = s[4 * c + 3]
            out[4 * c] = gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3
            out[4 * c + 1] = a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3
            out[4 * c + 2] = a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3)
            out[4 * c + 3] = gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2)
        }
        return out
    }
}

// MARK: - GCM (explicit J0, matches nura_crypto.py)

private struct U128 {
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

// MARK: - Nura session counters (spec §4.3)

private let kyleAAD: [UInt8] = Array("Kyle is awesome!".utf8)

private func makeJ0(nonce: [UInt8], counter: UInt32, deviceToApp: Bool)
    -> [UInt8]
{
    let c: UInt32 = counter | (deviceToApp ? 0x8000_0000 : 0)
    return nonce + [
        UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF),
        UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF),
    ]
}

private func advanceCounter(_ counter: UInt32, plainLen: Int) -> UInt32 {
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
}

// MARK: - Errors & state

enum NuraError: LocalizedError {
    case notReady, busy, timeout
    case malformed(String)
    case crypto(String)
    case status(String, Int)
    var errorDescription: String? {
        switch self {
        case .notReady: return "Not connected / handshake not complete"
        case .busy: return "A command is already in flight"
        case .timeout: return "Command timed out (no response)"
        case .malformed(let s): return "Bad response: \(s)"
        case .crypto(let s): return "Crypto error: \(s)"
        case .status(let c, let n): return "\(c) failed: \(gaiaStatusName(n))"
        }
    }
}

private func gaiaStatusName(_ b: Int) -> String {
    [
        0: "Success", 1: "NotSupported", 2: "NotAuthenticated",
        3: "InsufficientResource",
        4: "Authenticating", 5: "InvalidParameter", 6: "IncorrectState",
        7: "InProgress",
        8: "CryptoNotAuthenticated", 9: "CryptoInvalid", 10: "PayloadTooLong",
    ][b] ?? "Unknown(\(b))"
}

private func gaiaEventDescription(_ payload: [UInt8]) -> String? {
    guard payload.count >= 3 else { return nil }
    switch (payload[1], payload[2]) {
    case (0x05, 0x04): return "play/pause"
    case (0x06, 0x02): return "social mode ON"
    case (0x06, 0x00): return "social mode OFF"
    default: return nil
    }
}

enum ConnectionPhase: Equatable {
    case idle, scanning, connecting, discovering, handshaking, ready
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .discovering: return "Discovering services..."
        case .handshaking: return "Handshaking..."
        case .ready: return "Connected"
        case .failed(let s): return "Error: \(s)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
    var isIdle: Bool {
        if case .idle = self { return true }
        if case .failed = self { return true }
        return false
    }
}

enum SoundMode: String, CaseIterable, Identifiable {
    case personalised = "Personalised"
    case neutral = "Neutral"
    var id: String { rawValue }
    var byte: UInt8 { self == .personalised ? 0x00 : 0x01 }
}

// MARK: - BLE UUIDs / constants

private let gaiaServiceUUID = CBUUID(
    string: "00001100-D102-11E1-9B23-00025B00A5A5"
)
private let gaiaCommandUUID = CBUUID(
    string: "00001101-D102-11E1-9B23-00025B00A5A5"
)
private let gaiaResponseUUID = CBUUID(
    string: "00001102-D102-11E1-9B23-00025B00A5A5"
)
private let gaiaVendor: UInt16 = 0x6872
private let gaiaAckBit: UInt16 = 0x8000

private let cmdGetDeviceInfo: UInt16 = 0x0001
private let cmdCryptoGenerateChallenge: UInt16 = 0x0002
private let cmdCryptoValidateChallenge: UInt16 = 0x0003
private let cmdEncryptedCommand: UInt16 = 0x0006
private let cmdEncryptedResponse: UInt16 = 0x000A
private let cmdSetPersonalisedMode: UInt16 = 0x000C
private let cmdSetAncState: UInt16 = 0x0048
private let cmdGetAncState: UInt16 = 0x0049
private let cmdSetKickitParams: UInt16 = 0x004C
private let cmdGetKickitParams: UInt16 = 0x004D
private let cmdEventNotification: UInt16 = 0x800e

private let defaultNuraKey: [UInt8] = [
    0xe3, 0x15, 0xf1, 0x2f, 0x69, 0xb9, 0x3c, 0x8c,
    0x14, 0x51, 0x86, 0x3c, 0xd1, 0x83, 0x1e, 0x97,
]

private let nuraphoneBdAddrSuffix: [UInt8] = [
    0x74, 0x1a, 0xe0, 0x21, 0x07, 0x86,
]

private func hexStr(_ data: Data?) -> String {
    guard let d = data, !d.isEmpty else { return "<empty>" }
    return d.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Immersion parameter lookup

func kickitParams(for level: Int) -> [UInt8] {
    switch level {
    case 4: return [0x00, 0x04, 0x00, 0x02]
    case 3: return [0x00, 0x03, 0x00, 0x02]
    case 2: return [0x00, 0x02, 0x02, 0x02]
    case 1: return [0x00, 0x01, 0x02, 0x02]
    case 0: return [0x00, 0x00, 0x04, 0x02]
    case -1: return [0x00, 0x00, 0x04, 0x01]
    case -2: return [0x00, 0x00, 0x04, 0x00]
    default: return [0x00, 0x00, 0x04, 0x02]
    }
}

func decodeImmersionLevel(from pt: [UInt8]) -> Int? {
    guard pt.count >= 4 else { return nil }
    if pt[1] > 0 { return Int(pt[1]) }
    switch pt[3] {
    case 2: return 0
    case 1: return -1
    case 0: return -2
    default: return nil
    }
}

func decodeSocialMode(from pt: [UInt8]) -> Bool? {
    guard pt.count >= 3 else { return nil }
    return pt[2] != 0x00
}

// MARK: - NuraBLEManager (ObservableObject)

@MainActor
final class NuraBLEManager: NSObject, ObservableObject {

    @Published var phase: ConnectionPhase = .idle
    @Published var logs: [String] = []
    @Published var immersionLevel: Int = 0
    @Published var socialMode: Bool = false  // false = social OFF (normal)
    @Published var soundMode: SoundMode = .personalised

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var rspChar: CBCharacteristic?
    private var discoveringServices = false
    private var pendingServiceCount = 0

    private let nuraKey: [UInt8] = defaultNuraKey
    private var session: NuraSession?

    private var pendingAck: UInt16 = 0
    private var pendingMinLen: Int = 0
    private var pendingCompletion: ((Result<[UInt8], Error>) -> Void)?
    private var pendingFrame: Data?
    private var writeRetries = 0
    private let maxRetries = 5
    private var pollTimer: Timer?
    private var pollAttempts = 0
    private let maxPollAttempts = 80  // ~20 s

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    // MARK: - Public UI actions

    func connect() {
        guard phase.isIdle else { return }
        session = nil
        cmdChar = nil
        rspChar = nil
        peripheral = nil
        phase = .scanning
        addLog("Scanning for nuraphone...")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func disconnect() {
        stopPolling()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        session = nil
        cmdChar = nil
        rspChar = nil
        phase = .idle
        addLog("Disconnected")
    }

    func setImmersion(_ level: Int) {
        guard phase.isReady else {
            addLog("Not ready")
            return
        }
        addLog("-> SetKickitParams level \(level)")
        sendEncrypted(
            opcode: cmdSetKickitParams,
            params: kickitParams(for: level)
        ) { [weak self] result in
            switch result {
            case .success:
                self?.immersionLevel = level
                self?.addLog("<- Immersion set to \(level)")
            case .failure(let e):
                self?.addLog(
                    "<- SetKickitParams error: \(e.localizedDescription)"
                )
            }
        }
    }

    func setSocialMode(_ enabled: Bool) {
        guard phase.isReady else { return }
        let byte: UInt8 = enabled ? 0x01 : 0x00
        addLog("-> SetAncState social \(enabled ? "ON" : "OFF")")
        sendEncrypted(opcode: cmdSetAncState, params: [0x00, 0x00, byte]) {
            [weak self] result in
            switch result {
            case .success:
                self?.socialMode = enabled
                self?.addLog("<- Social mode \(enabled ? "ON" : "OFF")")
            case .failure(let e):
                self?.addLog("<- SetAncState error: \(e.localizedDescription)")
            }
        }
    }

    func setSoundMode(_ mode: SoundMode) {
        guard phase.isReady else { return }
        addLog("-> SetPersonalisedMode \(mode.rawValue)")
        sendEncrypted(opcode: cmdSetPersonalisedMode, params: [mode.byte]) {
            [weak self] result in
            switch result {
            case .success:
                self?.soundMode = mode
                self?.addLog("<- Sound mode \(mode.rawValue)")
            case .failure(let e):
                self?.addLog(
                    "<- SetPersonalisedMode error: \(e.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Logging

    func addLog(_ msg: String) {
        let ts = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )
        logs.append("[\(ts)] \(msg)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    // MARK: - GAIA frame send/receive

    private func sendGaiaFrame(
        cmd: UInt16,
        payload: [UInt8],
        expectedAck: UInt16,
        minResponseLen: Int = 0,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        guard cmdChar != nil, rspChar != nil else {
            completion(.failure(NuraError.notReady))
            return
        }
        pendingAck = expectedAck
        pendingMinLen = minResponseLen
        pendingCompletion = completion
        writeRetries = 0
        var frame = [
            UInt8((gaiaVendor >> 8) & 0xFF), UInt8(gaiaVendor & 0xFF),
            UInt8((cmd >> 8) & 0xFF), UInt8(cmd & 0xFF),
        ]
        frame += payload
        pendingFrame = Data(frame)
        writeGaiaFrame()
    }

    private func writeGaiaFrame() {
        guard let ch = cmdChar, let p = peripheral, let frame = pendingFrame
        else { return }
        let wType: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(frame, for: ch, type: wType)
        startPolling()
    }

    private func startPolling() {
        pollAttempts = 0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollTick() {
        guard pendingCompletion != nil else {
            stopPolling()
            return
        }
        pollAttempts += 1
        // Do NOT call readValue here: ATT Read responses overwrite characteristic.value
        // and race with the indication already in flight, causing payload truncation.
        // Rely solely on indications/notifications; this timer only serves as a timeout.
        if pollAttempts >= maxPollAttempts {
            stopPolling()
            let cb = pendingCompletion
            pendingCompletion = nil
            pendingAck = 0
            cb?(.failure(NuraError.timeout))
        }
    }

    private func resolveGAIAResponse(_ payload: [UInt8]) {
        stopPolling()
        let cb = pendingCompletion
        pendingCompletion = nil
        pendingAck = 0
        cb?(.success(payload))
    }

    // MARK: - Encrypted command (spec §4.3 / EntryAppEncryptedAuthenticated 0x0006)

    private var gaiaCommandBusy = false

    private func sendEncrypted(
        opcode: UInt16,
        params: [UInt8],
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        guard let session else {
            completion(.failure(NuraError.notReady))
            return
        }
        guard !gaiaCommandBusy else {
            completion(.failure(NuraError.busy))
            return
        }
        gaiaCommandBusy = true

        var plain: [UInt8] = [
            UInt8((opcode >> 8) & 0xFF), UInt8(opcode & 0xFF),
        ]
        plain += params
        let j0 = makeJ0(
            nonce: session.nonce,
            counter: session.encCtr,
            deviceToApp: false
        )
        let (ct, tag) = gcmWithJ0(
            key: session.key,
            j0: j0,
            aad: [],
            plaintext: plain
        )
        session.encCtr = advanceCounter(session.encCtr, plainLen: plain.count)

        addLog(
            String(
                format: "  enc opcode=0x%04x ctr=%d",
                opcode,
                session.encCtr - 1
            )
        )

        sendGaiaFrame(
            cmd: cmdEncryptedCommand,
            payload: tag + ct,
            expectedAck: cmdEncryptedResponse | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            self.gaiaCommandBusy = false
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let payload):
                guard !payload.isEmpty else {
                    completion(
                        .failure(
                            NuraError.malformed("empty encrypted response")
                        )
                    )
                    return
                }
                let status = Int(payload[0])
                guard status == 0 else {
                    completion(
                        .failure(
                            NuraError.status(
                                String(format: "0x%04x", opcode),
                                status
                            )
                        )
                    )
                    return
                }
                let body = Array(payload[1...])
                do {
                    let pt = try session.decryptDevToApp(body)
                    self.addLog(
                        String(
                            format: "  dec opcode=0x%04x plain=%@",
                            opcode,
                            hexStr(Data(pt))
                        )
                    )
                    completion(.success(pt))
                } catch {
                    completion(
                        .failure(
                            NuraError.crypto("tag mismatch decrypting response")
                        )
                    )
                }
            }
        }
    }

    // MARK: - Connection & GAIA sequence

    private func runGaiaSequence() {
        addLog("GAIA: GetDeviceInfo (0x0001)")
        sendGaiaFrame(
            cmd: cmdGetDeviceInfo,
            payload: [],
            expectedAck: cmdGetDeviceInfo | gaiaAckBit
        ) { [weak self] result in
            if case .success(let p) = result {
                self?.addLog("  device info: \(hexStr(Data(p)))")
            }
            self?.runHandshake()
        }
    }

    private func runHandshake() {
        phase = .handshaking
        addLog("GAIA: CryptoAppGenerateChallenge (0x0002)")
        sendGaiaFrame(
            cmd: cmdCryptoGenerateChallenge,
            payload: [],
            expectedAck: cmdCryptoGenerateChallenge | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.addLog(
                    "Handshake step 1 failed: \(e.localizedDescription)"
                )
                self.phase = .failed("Handshake failed")
            case .success(let payload):
                guard payload.count >= 17, payload[0] == 0 else {
                    let s = payload.first.map { Int($0) } ?? -1
                    self.addLog("CryptoGenerateChallenge status=\(s)")
                    self.phase = .failed("Handshake status \(s)")
                    return
                }
                let challenge = Array(payload[1..<17])
                self.addLog("  challenge=\(hexStr(Data(challenge)))")
                self.continueHandshake(challenge: challenge)
            }
        }
    }

    private func continueHandshake(challenge: [UInt8]) {
        var nonce = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 { nonce[i] = UInt8.random(in: 0...255) }
        addLog("  nonce=\(hexStr(Data(nonce)))")

        let j0App = makeJ0(nonce: nonce, counter: 1, deviceToApp: false)
        let (_, appGmac) = gcmWithJ0(
            key: nuraKey,
            j0: j0App,
            aad: challenge,
            plaintext: []
        )
        addLog("  app GMAC=\(hexStr(Data(appGmac)))")

        sendGaiaFrame(
            cmd: cmdCryptoValidateChallenge,
            payload: nonce + appGmac,
            expectedAck: cmdCryptoValidateChallenge | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.addLog(
                    "Handshake step 2 failed: \(e.localizedDescription)"
                )
                self.phase = .failed("Handshake failed")
            case .success(let payload):
                guard payload.count >= 17, payload[0] == 0 else {
                    let s = payload.first.map { Int($0) } ?? -1
                    self.addLog("CryptoValidate status=\(s)")
                    self.phase = .failed("Handshake status \(s)")
                    return
                }
                let devGmac = Array(payload[1..<17])
                self.addLog("  device GMAC=\(hexStr(Data(devGmac)))")
                do {
                    let j0Dev = makeJ0(
                        nonce: nonce,
                        counter: 1,
                        deviceToApp: true
                    )
                    _ = try gcmOpenJ0(
                        key: self.nuraKey,
                        j0: j0Dev,
                        aad: kyleAAD,
                        ciphertext: [],
                        tag: devGmac
                    )
                    self.addLog("  Device GMAC verified - session established")
                    self.session = NuraSession(key: self.nuraKey, nonce: nonce)
                    self.readInitialState()
                } catch {
                    self.addLog("  Device GMAC mismatch - wrong key?")
                    self.phase = .failed("Crypto: wrong key")
                }
            }
        }
    }

    private func readInitialState() {
        addLog("Reading initial state...")
        sendEncrypted(opcode: cmdGetKickitParams, params: [0x00]) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pt):
                if let lvl = decodeImmersionLevel(from: pt) {
                    self.immersionLevel = lvl
                    self.addLog("  immersion = \(lvl)")
                }
            case .failure(let e):
                self.addLog(
                    "  GetKickitParams error: \(e.localizedDescription)"
                )
            }
            self.sendEncrypted(opcode: cmdGetAncState, params: [0x00]) {
                [weak self] result2 in
                guard let self else { return }
                switch result2 {
                case .success(let pt):
                    if let on = decodeSocialMode(from: pt) {
                        self.socialMode = on
                        self.addLog("  social mode = \(on ? "ON" : "OFF")")
                    }
                case .failure(let e):
                    self.addLog(
                        "  GetAncState error: \(e.localizedDescription)"
                    )
                }
                self.phase = .ready
                self.addLog("Ready")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
// CBCentralManager is init'd with queue: .main, so all delegate callbacks run synchronously
// on the main thread - MainActor.assumeIsolated is safe.

extension NuraBLEManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                addLog("Bluetooth on")
                if case .scanning = phase {
                    central.scanForPeripherals(
                        withServices: nil,
                        options: [
                            CBCentralManagerScanOptionAllowDuplicatesKey: false
                        ]
                    )
                }
            case .poweredOff:
                addLog("Bluetooth OFF")
                phase = .failed("Bluetooth off")
            case .unauthorized:
                addLog("Bluetooth unauthorized")
                phase = .failed("Bluetooth unauthorized")
            default:
                addLog("Bluetooth state: \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name =
            peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "<no name>"
        var match = name.lowercased().contains("nuraphone")
        if !match,
            let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey]
                as? Data
        {
            match = [UInt8](mfg).suffix(6) == ArraySlice(nuraphoneBdAddrSuffix)
        }
        guard match else { return }

        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            central.stopScan()
            addLog("Found \"\(name)\" - connecting")
            phase = .connecting
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(
                peripheral,
                options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                ]
            )
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        MainActor.assumeIsolated {
            addLog("Connected - discovering services")
            phase = .discovering
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            addLog(
                "Failed to connect: \(error?.localizedDescription ?? "unknown")"
            )
            phase = .failed("Connect failed")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            stopPolling()
            session = nil
            cmdChar = nil
            rspChar = nil
            self.peripheral = nil
            if let e = error {
                addLog("Disconnected (error): \(e.localizedDescription)")
                phase = .failed("Disconnected")
            } else {
                addLog("Disconnected cleanly")
                phase = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension NuraBLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        MainActor.assumeIsolated {
            if let e = error {
                addLog("Service discovery error: \(e.localizedDescription)")
                return
            }
            let services = peripheral.services ?? []
            addLog("Found \(services.count) service(s)")
            pendingServiceCount = services.count
            for svc in services {
                peripheral.discoverCharacteristics(nil, for: svc)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            pendingServiceCount -= 1
            if let e = error {
                addLog(
                    "Char discovery error (\(service.uuid)): \(e.localizedDescription)"
                )
            } else {
                for ch in service.characteristics ?? [] {
                    if ch.uuid == gaiaCommandUUID {
                        cmdChar = ch
                        addLog("  GAIA CMD  char found")
                    }
                    if ch.uuid == gaiaResponseUUID {
                        rspChar = ch
                        addLog("  GAIA RSP  char found")
                    }
                    if ch.properties.contains(.notify)
                        || ch.properties.contains(.indicate)
                    {
                        peripheral.setNotifyValue(true, for: ch)
                    } else if ch.uuid == gaiaResponseUUID {
                        // Try subscribing even if not advertised; some firmwares under-report
                        peripheral.setNotifyValue(true, for: ch)
                    }
                }
            }
            if pendingServiceCount <= 0 {
                if cmdChar != nil, rspChar != nil {
                    runGaiaSequence()
                } else {
                    addLog("GAIA characteristics not found")
                    phase = .failed("GAIA chars not found")
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let e = error {
                addLog(
                    "Notify error (\(characteristic.uuid)): \(e.localizedDescription)"
                )
            } else {
                addLog(
                    "Subscribed to \(characteristic.uuid) isNotifying=\(characteristic.isNotifying)"
                )
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Capture before assumeIsolated; with Task { @MainActor } this value could be
        // overwritten by a readValue() ATT response before the closure ran.
        let uuid = characteristic.uuid
        let capturedValue = characteristic.value
        let capturedError = error

        MainActor.assumeIsolated {
            if let e = capturedError {
                if uuid == gaiaResponseUUID, pendingCompletion != nil { return }
                addLog("Value error (\(uuid)): \(e.localizedDescription)")
                return
            }
            guard uuid == gaiaResponseUUID,
                let data = capturedValue, data.count >= 4
            else { return }
            let vendor = (UInt16(data[0]) << 8) | UInt16(data[1])
            let cmd = (UInt16(data[2]) << 8) | UInt16(data[3])
            let payload = [UInt8](data[4...])
            guard vendor == gaiaVendor else { return }
            var logLine = String(
                format: "<- GAIA cmd=0x%04x (%d bytes) payload=%@",
                cmd, payload.count, hexStr(Data(payload))
            )
            if cmd == cmdEventNotification, payload.count >= 3 {
                if let desc = gaiaEventDescription(payload) { logLine += "  [\(desc)]" }
                if payload[1] == 0x06 { socialMode = payload[2] != 0x00 }
            }
            addLog(logLine)
            if cmd == pendingAck {
                if payload.count < pendingMinLen {
                    addLog(
                        String(
                            format: "  (ignoring: only %d byte(s), need ≥%d)",
                            payload.count,
                            pendingMinLen
                        )
                    )
                    return
                }
                resolveGAIAResponse(payload)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let capturedError = error
        MainActor.assumeIsolated {
            guard uuid == gaiaCommandUUID else { return }
            if let e = capturedError {
                addLog("Write error: \(e.localizedDescription)")
                let ns = e as NSError
                let isEnc =
                    ns.domain == CBATTErrorDomain
                    && (ns.code == CBATTError.insufficientEncryption.rawValue
                        || ns.code
                            == CBATTError.insufficientAuthentication.rawValue
                        || ns.code == CBATTError.insufficientResources.rawValue)
                if isEnc, writeRetries < maxRetries {
                    writeRetries += 1
                    let delay = 2.0 * Double(writeRetries)
                    addLog("  Encryption not ready, retry in \(Int(delay))s")
                    stopPolling()
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.writeGaiaFrame()
                    }
                } else {
                    stopPolling()
                    let cb = pendingCompletion
                    pendingCompletion = nil
                    cb?(.failure(e))
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        MainActor.assumeIsolated {
            addLog("Services changed - re-discovering")
            peripheral.discoverServices(nil)
        }
    }
}
