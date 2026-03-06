import Foundation
import Security
import Auth

// MARK: - KeychainStorage

/// AuthLocalStorage adapter backed by iOS Keychain.
/// Stores all values with kSecAttrAccessibleAfterFirstUnlock so background
/// sync tasks can read tokens after device reboot before first user unlock.
final class KeychainStorage: AuthLocalStorage {

    // MARK: - Properties

    private let service: String

    // MARK: - Initialization

    init(service: String = Bundle.main.bundleIdentifier ?? "com.vibewatch.auth") {
        self.service = service
    }

    // MARK: - AuthLocalStorage

    func store(key: String, value: Data) throws {
        // Delete-then-add pattern — Keychain does not support direct updates
        SecItemDelete(query(for: key) as CFDictionary)

        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ] as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }

        return result as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)

        // Treat "not found" as success — idempotent delete
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - Private Helpers

    private func query(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
    }
}

// MARK: - KeychainError

enum KeychainError: LocalizedError {
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        "Keychain error: \(self)"
    }
}
