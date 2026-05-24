import Foundation
import Security
import BastionIdentifiers

/// Errors that may surface from KeychainPassphraseStore.
public enum KeychainError: Error, CustomStringConvertible, Equatable {
    case itemNotFound
    case duplicateItem
    case authenticationFailed
    case underlying(OSStatus)

    public var description: String {
        switch self {
        case .itemNotFound:         return "Keychain item not found."
        case .duplicateItem:        return "Keychain item already exists."
        case .authenticationFailed: return "Keychain authentication failed."
        case .underlying(let s):    return "Keychain error (OSStatus \(s))."
        }
    }
}

/// Stores SSH key passphrases in the user's login keychain. Per
/// consensus + rubber-duck: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// so the passphrase NEVER syncs to iCloud Keychain across devices —
/// SSH passphrases are device-local secrets.
///
/// Item shape:
///   kSecClass:                 .genericPassword
///   kSecAttrService:           "Bastion SSH passphrase"
///   kSecAttrAccount:           absolute key file path (e.g. /Users/dan/.ssh/bastion_prod_ed25519)
///   kSecValueData:             utf8 passphrase
///   kSecAttrAccessible:        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
public struct KeychainPassphraseStore: Sendable {

    public let service: String

    public init(service: String = BastionIdentifiers.keychainService) {
        self.service = service
    }

    /// Add or update a passphrase for the given key path.
    public func set(passphrase: String, for keyPath: String) throws {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     keyPath
        ]
        let attributes: [String: Any] = [
            kSecValueData as String:       Data(passphrase.utf8),
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Try update first; if not found, add.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.underlying(updateStatus)
        }
        var addQuery = query
        for (k, v) in attributes { addQuery[k] = v }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem { throw KeychainError.duplicateItem }
        throw KeychainError.underlying(addStatus)
    }

    /// Look up a passphrase. Returns nil if absent (no error).
    public func passphrase(for keyPath: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     keyPath,
            kSecMatchLimit as String:      kSecMatchLimitOne,
            kSecReturnData as String:      kCFBooleanTrue!
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw KeychainError.underlying(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove a passphrase entry. Idempotent.
    public func remove(keyPath: String) throws {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     keyPath
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.underlying(status)
    }

    /// Enumerate all account names (key paths) we hold passphrases for.
    public func allKeyPaths() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecMatchLimit as String:      kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue!
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        if status != errSecSuccess { throw KeychainError.underlying(status) }
        guard let array = items as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Bulk-remove everything Bastion has stored (used by `bastion
    /// uninstall`).
    public func removeAll() throws {
        for path in try allKeyPaths() {
            try? remove(keyPath: path)
        }
    }
}
