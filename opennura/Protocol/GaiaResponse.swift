import Foundation

struct GaiaResponse {
    let vendorId: UInt16
    let rawCommandId: UInt16
    let payload: [UInt8]

    var commandId: UInt16 { rawCommandId & 0x1FFF }
    var status: UInt8 { payload.isEmpty ? 0 : payload[0] }
    var payloadExcludingStatus: [UInt8] { payload.count <= 1 ? [] : Array(payload[1...]) }
    var isAck: Bool { (rawCommandId & gaiaAckBit) != 0 }

    static func fromBLE(_ data: Data) -> GaiaResponse? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let vendor = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let cmd = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let payload = bytes.count > 4 ? Array(bytes[4...]) : []
        return GaiaResponse(vendorId: vendor, rawCommandId: cmd, payload: payload)
    }

    static func fromRFCOMM(_ bytes: [UInt8]) throws -> GaiaResponse {
        guard bytes.count >= 8 else {
            throw NuraError.malformed("RFCOMM frame too short")
        }
        guard bytes[0] == 0xFF else {
            throw NuraError.malformed("invalid SOF")
        }

        let flags = bytes[2]
        let usesLengthExtension = (flags & 0x02) != 0
        let headerLength = usesLengthExtension ? 9 : 8

        guard bytes.count >= headerLength else {
            throw NuraError.malformed("frame too short for header")
        }

        let vendorOffset = usesLengthExtension ? 5 : 4
        let commandOffset = usesLengthExtension ? 7 : 6
        let payloadOffset = headerLength

        let vendor = (UInt16(bytes[vendorOffset]) << 8) | UInt16(bytes[vendorOffset + 1])
        let rawCmd = (UInt16(bytes[commandOffset]) << 8) | UInt16(bytes[commandOffset + 1])
        let payload = bytes.count > payloadOffset ? Array(bytes[payloadOffset...]) : []

        return GaiaResponse(vendorId: vendor, rawCommandId: rawCmd, payload: payload)
    }
}
