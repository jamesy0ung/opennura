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
}
