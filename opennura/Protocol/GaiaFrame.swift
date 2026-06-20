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

    var rfcommData: Data {
        let usesLengthExtension = payload.count > 255
        let flags: UInt8 = usesLengthExtension ? 0x02 : 0x00
        var frame: [UInt8] = [0xFF, 0x01, flags]

        if usesLengthExtension {
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(UInt8(payload.count))
        }

        frame.append(UInt8((gaiaVendor >> 8) & 0xFF))
        frame.append(UInt8(gaiaVendor & 0xFF))
        frame.append(UInt8((commandId >> 8) & 0xFF))
        frame.append(UInt8(commandId & 0xFF))
        frame += payload
        return Data(frame)
    }
}
