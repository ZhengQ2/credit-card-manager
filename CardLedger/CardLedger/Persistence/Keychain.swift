import Foundation
import Security

/// Device-only Keychain entries (design §6): never synced, unavailable while locked, not restored to other devices.
enum Keychain {
    private static let service = "local.prototype.CardLedger"

    enum Key: String {
        case databaseKey = "db-key-v1"
        case serviceCredential = "service-credential-v1"
    }

    enum ReadError: Error {
        case osStatus(OSStatus)
    }

    /// Reads an item, returning `nil` ONLY when the item does not exist (`errSecItemNotFound`).
    /// All other Keychain errors (such as `errSecInteractionNotAllowed` while locked) throw so callers
    /// never mistake a locked Keychain for a missing key.
    static func read(_ key: Key) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess { return out as? Data }
        if status == errSecItemNotFound { return nil }
        throw ReadError.osStatus(status)
    }

    static func data(_ key: Key) -> Data? {
        try? read(key)
    }

    @discardableResult
    static func set(_ value: Data, for key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        let update: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attrs = query
        attrs[kSecValueData as String] = value
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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

    /// Returns the existing 256-bit key or creates one with the system CSPRNG when no database exists yet.
    /// Never overwrites a key when the Keychain is locked or when an existing database file is already on disk.
    static func databaseKey(databaseExists: Bool = false) throws -> Data {
        let existing: Data?
        do { existing = try read(.databaseKey) }
        catch { throw DatabaseError.keyUnavailable }

        if let k = existing {
            guard k.count == 32 else { throw DatabaseError.keyUnavailable }
            return k
        }
        guard !databaseExists else { throw DatabaseError.keyUnavailable }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DatabaseError.keyUnavailable
        }
        let key = Data(bytes)
        guard set(key, for: .databaseKey) else { throw DatabaseError.keyUnavailable }
        return key
    }
}
