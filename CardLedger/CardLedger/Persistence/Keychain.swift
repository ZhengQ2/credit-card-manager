import Foundation
import Security

/// Device-only Keychain entries (design §6): never synced, unavailable while locked, not restored to other devices.
enum Keychain {
    private static let service = "local.prototype.CardLedger"

    enum Key: String {
        case databaseKey = "db-key-v1"
        case serviceCredential = "service-credential-v1"
    }

    static func data(_ key: Key) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func set(_ value: Data, for key: Key) -> Bool {
        delete(key)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: value,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Returns the existing 256-bit key or creates one with the system CSPRNG.
    static func databaseKey() throws -> Data {
        if let k = data(.databaseKey), k.count == 32 { return k }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DatabaseError.keyUnavailable
        }
        let key = Data(bytes)
        guard set(key, for: .databaseKey) else { throw DatabaseError.keyUnavailable }
        return key
    }
}
