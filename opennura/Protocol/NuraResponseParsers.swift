import Foundation

enum NuraResponseParsers {

    static func decodeDeviceInfo(_ payload: [UInt8]) -> NuraDeviceInfo? {
        let body: [UInt8]
        switch payload.count {
        case 8: body = payload
        case 9 where payload[0] == 0: body = Array(payload[1...])
        default: return nil
        }
        return NuraDeviceInfo(
            serialNumber: readInt32BE(body, 0),
            firmwareVersion: readInt32BE(body, 4)
        )
    }

    static func decodeCurrentProfileId(_ payload: [UInt8]) -> Int? {
        guard !payload.isEmpty else { return nil }
        return Int(payload[0])
    }

    static func decodeProfileName(_ payload: [UInt8]) -> String? {
        guard payload.count == 33, payload[0] == 0x01 else { return nil }
        let nameBytes = Array(payload[1...])
        let terminatorIndex = nameBytes.firstIndex(of: 0x00) ?? nameBytes.count
        guard terminatorIndex > 0 else { return nil }
        return String(bytes: nameBytes[0..<terminatorIndex], encoding: .utf8)
    }

    static func decodeAncState(_ payload: [UInt8]) -> NuraAncState? {
        guard payload.count >= 2 else { return nil }
        return NuraAncState(
            ancEnabled: payload[0] != 0x00,
            passthroughEnabled: payload[1] != 0x00
        )
    }

    static func decodeAncLevel(_ payload: [UInt8]) -> Int? {
        guard !payload.isEmpty else { return nil }
        return Int(payload[0])
    }

    static func decodeBooleanFlag(_ payload: [UInt8]) -> Bool? {
        guard !payload.isEmpty else { return nil }
        return payload[0] != 0x00
    }

    static func decodeBatteryStatus(_ payload: [UInt8]) -> NuraBatteryStatus? {
        guard payload.count >= 11 else { return nil }
        return NuraBatteryStatus(
            batteryVoltageMillivolts: readUInt16BE(payload, 0),
            batteryLevelRaw: Int(payload[2]),
            batteryPercentage: Int(payload[3]),
            chargerStateRaw: Int(payload[4]),
            chargerVoltageMillivolts: readUInt16BE(payload, 5),
            chargerLevelRaw: Int(payload[7]),
            ntcVoltageMillivolts: readUInt16BE(payload, 8),
            ntcLevelRaw: Int(payload[10])
        )
    }

    static func decodeKickitState(_ payload: [UInt8]) -> NuraKickitState? {
        guard payload.count >= 2 else { return nil }
        return NuraKickitState(rawLevel: Int(payload[0]), enabled: payload[1] == 0x01)
    }

    static func decodeClassicKickitParams(_ payload: [UInt8]) -> NuraClassicKickitParams? {
        guard payload.count == 3 else { return nil }
        return NuraClassicKickitParams(drcRaw: payload[0], lpfRaw: payload[1], gainRaw: payload[2])
    }

    static func decodeButtonConfiguration(
        _ payload: [UInt8],
        supportsDoubleTap: Bool,
        supportsTripleTap: Bool
    ) -> NuraButtonConfiguration? {
        let expectedLength = supportsTripleTap ? 8 : (supportsDoubleTap ? 6 : 2)
        guard payload.count == expectedLength else { return nil }
        return NuraButtonConfiguration(
            leftSingleTap: NuraButtonFunction.fromRawByte(payload[0]),
            rightSingleTap: NuraButtonFunction.fromRawByte(payload[1]),
            leftDoubleTap: supportsDoubleTap ? NuraButtonFunction.fromRawByte(payload[2]) : nil,
            rightDoubleTap: supportsDoubleTap ? NuraButtonFunction.fromRawByte(payload[3]) : nil,
            leftTapAndHold: supportsDoubleTap ? NuraButtonFunction.fromRawByte(payload[4]) : nil,
            rightTapAndHold: supportsDoubleTap ? NuraButtonFunction.fromRawByte(payload[5]) : nil,
            leftTripleTap: supportsTripleTap ? NuraButtonFunction.fromRawByte(payload[6]) : nil,
            rightTripleTap: supportsTripleTap ? NuraButtonFunction.fromRawByte(payload[7]) : nil
        )
    }

    static func decodeDialConfiguration(_ payload: [UInt8]) -> NuraDialConfiguration? {
        let normalized: [UInt8]
        switch payload.count {
        case 2: normalized = payload
        case 6: normalized = Array(payload[0..<2])
        default: return nil
        }
        return NuraDialConfiguration(
            left: NuraDialFunction.fromRawByte(normalized[0]),
            right: NuraDialFunction.fromRawByte(normalized[1])
        )
    }

    // MARK: - Byte helpers

    private static func readInt32BE(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }

    private static func readUInt16BE(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }
}
