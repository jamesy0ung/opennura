import Foundation

struct NuraConfig: Codable {
    var devices: [NuraDeviceConfigEntry] = []
    
    // Backend-assisted provisioning state. All optional so that older
    // config.json files (which only stored `devices`) still decode cleanly.
    var apiBase: String?
    var uuid: String?
    var auth: NuraAuthConfig?
    var lastConnectedSerial: String?
    /// App-side custom profile labels, keyed by "<serial>.<profileId>". These
    /// are display-only and never written to the headphones.
    var profileLabels: [String: String]?
    
    /// The API base to use, defaulting to the primary backend.
    var resolvedApiBase: String {
        let value = apiBase ?? ""
        return value.isEmpty ? "https://api-p3.nuraphone.com/" : value
    }
    
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
    
    /// Returns the persisted UUID, generating and storing a new one if absent.
    mutating func ensureUuid() -> String {
        if let uuid, !uuid.isEmpty { return uuid }
        let generated = UUID().uuidString
        uuid = generated
        return generated
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
    
    enum CodingKeys: String, CodingKey {
        case userEmail, authUid, accessToken, clientKey, tokenType, tokenExpiryUnix
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userEmail = try c.decodeIfPresent(String.self, forKey: .userEmail)
        authUid = try c.decodeIfPresent(String.self, forKey: .authUid)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        clientKey = try c.decodeIfPresent(String.self, forKey: .clientKey)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        tokenExpiryUnix = try c.decodeIfPresent(Int64.self, forKey: .tokenExpiryUnix)
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
