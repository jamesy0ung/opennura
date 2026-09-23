import Foundation
import Security

/// Thin wrapper over the system Keychain for the app's secrets (the per-device
/// key and the Nura account tokens). Generic-password items, scoped to this
/// app's service, accessible after first unlock and never synced to iCloud.
enum NuraKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "org.jamesyoung.opennura") + ".secrets"
    
    /// Stores (or replaces) a string value for an account. Returns true on success.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
    
    /// Reads the string value for an account, or nil if absent.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
                else { return nil }
        return string
    }
    
    static func delete(_ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
    }
    
    // MARK: - Account keys
    
    static let authAccount = "auth"
    static func deviceKeyAccount(serial: String) -> String { "deviceKey.\(serial)" }
}
