import Foundation

/// Persists app configuration to a JSON file. All fields, including secrets
/// (device keys and auth tokens), are stored on disk. Legacy installs that
/// stored secrets only in the Keychain have them overlaid on load.
final class NuraConfigStore {
    private let fileURL: URL
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "opennura"
        let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Restrict the directory even if it already existed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        fileURL = dir.appendingPathComponent("config.json")
    }
    
    func load() -> NuraConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            // No file yet: still surface any secrets already in the Keychain.
            var fresh = NuraConfig()
            overlaySecrets(into: &fresh)
            return fresh
        }
        var config: NuraConfig
        do {
            config = try JSONDecoder().decode(NuraConfig.self, from: data)
        } catch {
            config = NuraConfig()
        }
        
        // Detect whether the on-disk file still carries plaintext secrets
        // (a legacy file, or one written before this version).
        let fileHadAuthSecret = config.auth?.hasAuthenticatedSession == true
        let fileHadDeviceKey = config.devices.contains { !$0.deviceKey.isEmpty }
        
        overlaySecrets(into: &config)
        
        // Legacy file had Keychain-only secrets; rewrite to include them on disk.
        if fileHadAuthSecret || fileHadDeviceKey {
            save(config)
        }
        return config
    }
    
    /// Fills in secret fields from the Keychain for legacy installs that stored
    /// secrets there; leaves any value already in `config` untouched.
    private func overlaySecrets(into config: inout NuraConfig) {
        if let authJSON = NuraKeychain.get(NuraKeychain.authAccount),
           let authData = authJSON.data(using: .utf8),
           let auth = try? JSONDecoder().decode(NuraAuthConfig.self, from: authData) {
            config.auth = auth
        }
        for index in config.devices.indices {
            let serial = config.devices[index].deviceSerial
            if let key = NuraKeychain.get(NuraKeychain.deviceKeyAccount(serial: serial)) {
                config.devices[index].deviceKey = key
            }
        }
    }
    
    func save(_ config: NuraConfig) {
        let onDisk = config
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(onDisk)
            try data.write(to: fileURL, options: .atomic)
            // Even without secrets the file still has PII (serials, uuid);
            // keep it readable only by the current user.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Config save is best-effort.
        }
    }
    
    /// Removes a device's key from the Keychain (used when a device is deleted).
    func forgetDeviceKey(serial: String) {
        NuraKeychain.delete(NuraKeychain.deviceKeyAccount(serial: serial))
    }
}
