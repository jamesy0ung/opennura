import Foundation

struct NuraConfig: Codable {
    var apiBase: String = "https://api-p3.nuraphone.com/"
    var uuid: String = UUID().uuidString
    var auth: NuraAuthConfig = NuraAuthConfig()
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

struct NuraAuthConfig: Codable {
    var userEmail: String?
    var authUid: String?
    var accessToken: String?
    var clientKey: String?
    var tokenType: String = "Bearer"
    var tokenExpiryUnix: Int64?

    var hasAuthenticatedSession: Bool {
        guard let accessToken, !accessToken.isEmpty,
              let clientKey, !clientKey.isEmpty,
              let authUid, !authUid.isEmpty
        else { return false }
        return true
    }
}

struct NuraDeviceConfigEntry: Codable {
    var type: String = "Nuraphone"
    var deviceAddress: String
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
