import CoreBluetooth
import Foundation

// MARK: - BLE UUIDs

let gaiaServiceUUID = CBUUID(
    string: "00001100-D102-11E1-9B23-00025B00A5A5"
)
let gaiaCommandUUID = CBUUID(
    string: "00001101-D102-11E1-9B23-00025B00A5A5"
)
let gaiaResponseUUID = CBUUID(
    string: "00001102-D102-11E1-9B23-00025B00A5A5"
)

// MARK: - GAIA protocol constants

let gaiaVendor: UInt16 = 0x6872
let gaiaAckBit: UInt16 = 0x8000

// MARK: - Unencrypted commands

let cmdGetDeviceInfo: UInt16 = 0x0001
let cmdCryptoGenerateChallenge: UInt16 = 0x0002
let cmdCryptoValidateChallenge: UInt16 = 0x0003
let cmdEncryptedCommand: UInt16 = 0x0006
let cmdEncryptedResponse: UInt16 = 0x000A
let cmdEventNotification: UInt16 = 0x800e

// MARK: - Encrypted command opcodes

let cmdGetProfileName: UInt16 = 0x001A
let cmdSelectProfile: UInt16 = 0x001B
let cmdGetCurrentProfileId: UInt16 = 0x0041
let cmdGetGenericModeEnabled: UInt16 = 0x0042
let cmdSetAncLevel: UInt16 = 0x0047
let cmdSetAncState: UInt16 = 0x0048
let cmdGetAncState: UInt16 = 0x0049
let cmdGetAncLevel: UInt16 = 0x004A
let cmdGetGlobalAncEnabled: UInt16 = 0x004B
let cmdSetKickitParams: UInt16 = 0x004C
let cmdGetKickitParams: UInt16 = 0x004D
let cmdGetKickitState: UInt16 = 0x004E
let cmdSetGlobalAncEnabled: UInt16 = 0x004F
let cmdSetButtonConfig: UInt16 = 0x0050
let cmdGetButtonConfig: UInt16 = 0x0051
let cmdSetKickitState: UInt16 = 0x0052
let cmdGetSpatialState: UInt16 = 0x0053
let cmdSetSpatialState: UInt16 = 0x0054
let cmdSetDialConfig: UInt16 = 0x0005
let cmdGetDialConfig: UInt16 = 0x0006
let cmdGetDeepSleepTimeout: UInt16 = 0x006C
let cmdSetVoicePromptGain: UInt16 = 0x0072
let cmdGetButtonConfigV2: UInt16 = 0x0073
let cmdSetButtonConfigV2: UInt16 = 0x0074
let cmdGetBatteryStatus: UInt16 = 0x007F
let cmdSetPersonalisedMode: UInt16 = 0x00B3
let cmdGetKickitEnabled: UInt16 = 0x00B4
let cmdSetKickitEnabled: UInt16 = 0x00B5
let cmdSetButtonConfigV1: UInt16 = 0x00B6
let cmdGetButtonConfigV1: UInt16 = 0x00B7
let cmdGetVisualisationData: UInt16 = 0x00B8

// MARK: - Default encryption key

let defaultNuraKey: [UInt8] = [
    0xe3, 0x15, 0xf1, 0x2f, 0x69, 0xb9, 0x3c, 0x8c,
    0x14, 0x51, 0x86, 0x3c, 0xd1, 0x83, 0x1e, 0x97,
]

// MARK: - Nuraphone BD address suffix for BLE matching

nonisolated(unsafe) let nuraphoneBdAddrSuffix: [UInt8] = [
    0x74, 0x1a, 0xe0, 0x21, 0x07, 0x86,
]

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

func gaiaStatusName(_ b: Int) -> String {
    [
        0: "Success", 1: "NotSupported", 2: "NotAuthenticated",
        3: "InsufficientResource",
        4: "Authenticating", 5: "InvalidParameter", 6: "IncorrectState",
        7: "InProgress",
        8: "CryptoNotAuthenticated", 9: "CryptoInvalid", 10: "PayloadTooLong",
    ][b] ?? "Unknown(\(b))"
}

func gaiaEventDescription(_ payload: [UInt8]) -> String? {
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

// MARK: - Helpers

func hexStr(_ data: Data?) -> String {
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

func decodeAncEnabled(from pt: [UInt8]) -> Bool? {
    guard pt.count >= 2 else { return nil }
    return pt[1] != 0x00
}

func decodeSocialMode(from pt: [UInt8]) -> Bool? {
    guard pt.count >= 3 else { return nil }
    return pt[2] != 0x00
}
