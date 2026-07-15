import Foundation

struct GaiaFrame {
    let commandId: UInt16
    let payload: [UInt8]

    var bleData: Data {
        var frame = [
            UInt8((gaiaVendor >> 8) & 0xFF), UInt8(gaiaVendor & 0xFF),
            UInt8((commandId >> 8) & 0xFF), UInt8(commandId & 0xFF),
        ]
        frame += payload
        return Data(frame)
    }
}
