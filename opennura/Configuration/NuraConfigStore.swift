import Foundation

/// Persists app configuration. Non-secret metadata (serials, names, firmware,
/// uuid) lives in a JSON file; secrets (each device's key and the Nura account
/// tokens) live in the Keychain. Legacy config.json files that still contain
/// secrets are migrated into the Keychain on load and then stripped from disk.
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
        
        // If the file held secrets, migrate them into the Keychain and rewrite
        // the file without them. save() only strips a secret from disk once it
        // has been verified in the Keychain, so a Keychain failure never loses
        // the key.
        if fileHadAuthSecret || fileHadDeviceKey {
            save(config)
        }
        return config
    }
    
    /// Fills in secret fields from the Keychain where present, leaving any
    /// value already in `config` (i.e. from a legacy file) untouched otherwise.
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
        var onDisk = config
        
        // Move the auth tokens into the Keychain; only drop them from the file
        // once the Keychain write is verified.
        if let auth = config.auth,
           let authData = try? JSONEncoder().encode(auth),
           let authJSON = String(data: authData, encoding: .utf8) {
            if NuraKeychain.set(authJSON, account: NuraKeychain.authAccount),
               NuraKeychain.get(NuraKeychain.authAccount) != nil {
                onDisk.auth = nil
            }
        }
        
        // Same for each device key.
        onDisk.devices = config.devices.map { entry in
            var stripped = entry
            if !entry.deviceKey.isEmpty {
                let account = NuraKeychain.deviceKeyAccount(serial: entry.deviceSerial)
                if NuraKeychain.set(entry.deviceKey, account: account),
                   NuraKeychain.get(account) != nil {
                    stripped.deviceKey = ""
                }
            }
            return stripped
        }
        
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
