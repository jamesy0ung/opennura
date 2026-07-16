import Foundation

struct NuraConfig: Codable {
    var devices: [NuraDeviceConfigEntry] = []

    func deviceBySerial(_ serial: String) -> NuraDeviceConfigEntry? {
        devices.first { $0.deviceSerial == serial }
    }

    mutating func upsertDevice(_ device: NuraDeviceConfigEntry) {
        if let index = devices.firstIndex(where: { $0.deviceSerial == device.deviceSerial }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }
}

struct NuraDeviceConfigEntry: Codable {
    var type: String = "Nuraphone"
    var deviceSerial: String
    var friendlyName: String = ""
    var firmwareVersion: Int = 0
    var maxPacketLengthHint: Int = 182
    var isNuraNowDevice: Bool = false
    var lastProvisionedUtc: String?
    var deviceKey: String

    func getDeviceKeyBytes() -> [UInt8]? {
        guard let data = Data(base64Encoded: deviceKey), data.count == 16 else { return nil }
        return [UInt8](data)
    }

    func withDeviceKeyBytes(_ keyBytes: [UInt8]) -> NuraDeviceConfigEntry {
        var copy = self
        copy.deviceKey = Data(keyBytes).base64EncodedString()
        return copy
    }
}
