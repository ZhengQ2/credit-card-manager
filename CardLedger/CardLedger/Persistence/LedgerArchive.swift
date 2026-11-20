import CommonCrypto
import CryptoKit
import Foundation
import Security

enum LedgerArchiveError: Error, LocalizedError, Equatable {
    case passphraseTooShort(minimum: Int)
    case passphraseTooLong(maximum: Int)
    case emptyPassphrase
    case fileTooLarge
    case invalidFormat
    case unsupportedArchiveVersion(Int)
    case decryptionFailed
    case corruptedPayload
    case keyDerivationFailed
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .passphraseTooShort(let min):
            "Use a passphrase of at least \(min) characters to protect your ledger."
        case .passphraseTooLong(let max):
            "Use a passphrase of at most \(max) characters."
        case .emptyPassphrase:
            "Enter the passphrase used when this archive was created."
        case .fileTooLarge:
            "This file is too large to be a Card Ledger archive."
        case .invalidFormat:
            "This file is not a valid Card Ledger encrypted archive."
        case .unsupportedArchiveVersion(let v):
            "This archive uses a newer format (v\(v)). Update Card Ledger before restoring it."
        case .decryptionFailed:
            "Incorrect passphrase or damaged archive file."
        case .corruptedPayload:
            "The archive contents are damaged or incomplete. Your ledger was not changed."
        case .keyDerivationFailed:
            "Could not derive an encryption key on this device. Try again."
        case .syncInProgress:
            "Wait for the current bank sync to finish before restoring an archive."
        }
    }
}

/// Complete, versioned snapshot of every local SQLCipher table in Card Ledger.
/// Contains only on-device ledger data and preferences — never Keychain keys, API tokens, or Plaid secrets.
struct LedgerSnapshot: Codable, Equatable, Sendable {
    struct ConnectionRow: Codable, Equatable, Sendable {
        let id: String
        let institution: String
        let country: String
        let environment: String
        let status: String
        let cursor: String?
        let lastSync: String?
        let historyStatus: String?
    }

    struct CardRow: Codable, Equatable, Sendable {
        let id: String
        let nickname: String
        let productId: String
        let mask: String?
        let openedOn: String?
        let renewalDate: String?
        let renewalPrecision: String?
        let renewalSource: String?
        let connectionId: String?
        let createdAt: String
        let isAU: Bool
        let openedStatus: String?
    }

    struct SourceAccountRow: Codable, Equatable, Sendable {
        let id: String
        let connectionId: String
        let name: String
        let mask: String?
        let type: String
        let subtype: String?
        let currency: String?
        let cardId: String?
        let ignored: Bool
    }

    struct TransactionRow: Codable, Equatable, Sendable {
        let id: String
        let cardId: String
        let provenance: String
        let sourceId: String
        let amountMinor: Int64
        let currency: String?
        let posted: String
        let authorized: String?
        let merchant: String
        let originalDescription: String
        let category: String
        let kind: String
        let pending: Bool
        let mcc: String?
    }

    struct DecisionRow: Codable, Equatable, Sendable {
        let creditId: String
        let kind: String
        let periodId: String?
        let decidedAt: String
    }

    struct CategoryOverrideRow: Codable, Equatable, Sendable {
        let txnId: String
        let category: String
        let editedAt: String
    }

    struct WelcomeOfferRow: Codable, Equatable, Sendable {
        let id: String
        let cardId: String
        let kind: String
        let start: String
        let months: Int
        let currency: String
        let minSpendMinor: Int64?
        let points: Double?
        let cashMinor: Int64?
        let extraMultiplier: Double?
        let categories: String?
        let spendCapMinor: Int64?
        let notes: String?
        let earned: Bool
    }

    struct BenefitUsageRow: Codable, Equatable, Sendable {
        let id: String
        let periodId: String
        let amountMinor: Int64
        let currency: String
        let usedOn: String
        let note: String?
        let loggedAt: String
    }

    struct AwardCertificateRow: Codable, Equatable, Sendable {
        let id: String
        let cardId: String
        let ruleId: String
        let issuedOn: String
        let expiresOn: String
        let redeemedOn: String?
        let note: String?
    }

    struct SettingRow: Codable, Equatable, Sendable {
        let key: String
        let value: String
    }

    struct Summary: Equatable, Sendable {
        let exportedAt: Date?
        let cardCount: Int
        let transactionCount: Int
        let decisionCount: Int
        let overrideCount: Int
        let welcomeOfferCount: Int
        let certificateCount: Int
        let settingCount: Int
    }

    let archiveVersion: Int
    let schemaVersion: Int
    let exportedAt: String
    let connections: [ConnectionRow]
    let cards: [CardRow]
    let sourceAccounts: [SourceAccountRow]
    let transactions: [TransactionRow]
    let decisions: [DecisionRow]
    let categoryOverrides: [CategoryOverrideRow]
    let welcomeOffers: [WelcomeOfferRow]
    let benefitUsages: [BenefitUsageRow]
    let awardCertificates: [AwardCertificateRow]
    let settings: [SettingRow]

    var summary: Summary {
        let iso = ISO8601DateFormatter()
        return Summary(
            exportedAt: iso.date(from: exportedAt),
            cardCount: cards.count,
            transactionCount: transactions.count,
            decisionCount: decisions.count,
            overrideCount: categoryOverrides.count,
            welcomeOfferCount: welcomeOffers.count,
            certificateCount: awardCertificates.count,
            settingCount: settings.count
        )
    }

    /// Validates structural and referential integrity before touching the local database.
    func validate() throws {
        guard archiveVersion == LedgerArchive.currentArchiveVersion else {
            throw archiveVersion > LedgerArchive.currentArchiveVersion
                ? LedgerArchiveError.unsupportedArchiveVersion(archiveVersion)
                : LedgerArchiveError.corruptedPayload
        }
        guard (1...LedgerArchive.currentSchemaVersion).contains(schemaVersion) else {
            throw schemaVersion > LedgerArchive.currentSchemaVersion
                ? LedgerArchiveError.unsupportedArchiveVersion(schemaVersion)
                : LedgerArchiveError.corruptedPayload
        }

        let connectionIDs = Set(connections.map(\.id))
        guard connectionIDs.count == connections.count else { throw LedgerArchiveError.corruptedPayload }

        let cardIDs = Set(cards.map(\.id))
        guard cardIDs.count == cards.count else { throw LedgerArchiveError.corruptedPayload }
        for card in cards {
            if let connID = card.connectionId, !connectionIDs.contains(connID) {
                throw LedgerArchiveError.corruptedPayload
            }
        }

        let sourceAccountIDs = Set(sourceAccounts.map(\.id))
        guard sourceAccountIDs.count == sourceAccounts.count else { throw LedgerArchiveError.corruptedPayload }
        for account in sourceAccounts {
            guard connectionIDs.contains(account.connectionId) else { throw LedgerArchiveError.corruptedPayload }
            if let cardID = account.cardId, !cardIDs.contains(cardID) {
                throw LedgerArchiveError.corruptedPayload
            }
        }

        var txnIDs: Set<String> = []
        var sourceIDs: Set<String> = []
        for txn in transactions {
            guard cardIDs.contains(txn.cardId),
                  txnIDs.insert(txn.id).inserted,
                  sourceIDs.insert(txn.sourceId).inserted else {
                throw LedgerArchiveError.corruptedPayload
            }
        }

        guard Set(decisions.map(\.creditId)).count == decisions.count else {
            throw LedgerArchiveError.corruptedPayload
        }
        guard Set(categoryOverrides.map(\.txnId)).count == categoryOverrides.count else {
            throw LedgerArchiveError.corruptedPayload
        }

        let offerIDs = Set(welcomeOffers.map(\.id))
        guard offerIDs.count == welcomeOffers.count else { throw LedgerArchiveError.corruptedPayload }
        for offer in welcomeOffers {
            guard cardIDs.contains(offer.cardId),
                  offer.points.map(\.isFinite) ?? true,
                  offer.extraMultiplier.map(\.isFinite) ?? true else {
                throw LedgerArchiveError.corruptedPayload
            }
        }

        guard Set(benefitUsages.map(\.id)).count == benefitUsages.count else {
            throw LedgerArchiveError.corruptedPayload
        }

        let certIDs = Set(awardCertificates.map(\.id))
        guard certIDs.count == awardCertificates.count else { throw LedgerArchiveError.corruptedPayload }
        for cert in awardCertificates {
            guard cardIDs.contains(cert.cardId) else { throw LedgerArchiveError.corruptedPayload }
        }

        guard Set(settings.map(\.key)).count == settings.count else {
            throw LedgerArchiveError.corruptedPayload
        }
    }
}

/// Passphrase-encrypted single-file archive format (`CLBK` v1):
/// - 4-byte ASCII magic `"CLBK"`
/// - 1-byte format version (`1`)
/// - 1-byte KDF ID (`1` = PBKDF2-HMAC-SHA256)
/// - 4-byte big-endian iteration count (default 600,000)
/// - 32-byte random salt
/// - 12-byte random AES-256-GCM nonce
/// - AES-256-GCM ciphertext of UTF-8 JSON `LedgerSnapshot` (authenticated with the 42-byte header as AAD)
/// - 16-byte AES-256-GCM authentication tag
enum LedgerArchive {
    static let fileExtension = "cardledger"
    static let currentArchiveVersion = 1
    // Must match the highest `user_version` in `LedgerRepository.migrate()`.
    static let currentSchemaVersion = 12
    static let minimumPassphraseLength = 12
    static let maximumPassphraseLength = 256
    static let maximumArchiveBytes = 100 * 1024 * 1024

    private static let magic: [UInt8] = [0x43, 0x4C, 0x42, 0x4B] // "CLBK"
    private static let containerVersion: UInt8 = 1
    private static let kdfPBKDF2SHA256: UInt8 = 1
    static let defaultIterations: UInt32 = 600_000
    private static let minIterations: UInt32 = 600_000
    private static let maxIterations: UInt32 = 5_000_000
    private static let saltLength = 32
    private static let headerLength = 4 + 1 + 1 + 4 + saltLength // 42 bytes
    private static let nonceLength = 12
    private static let tagLength = 16

    static func validateExportPassphrase(_ passphrase: String) throws {
        let count = passphrase.unicodeScalars.count
        guard count >= minimumPassphraseLength else {
            throw LedgerArchiveError.passphraseTooShort(minimum: minimumPassphraseLength)
        }
        guard count <= maximumPassphraseLength else {
            throw LedgerArchiveError.passphraseTooLong(maximum: maximumPassphraseLength)
        }
    }

    static func defaultFilename(today: Date = Day.today) -> String {
        "CardLedger-\(Day.key(today)).\(fileExtension)"
    }

    static func encrypt(_ snapshot: LedgerSnapshot, passphrase: String) throws -> Data {
        try validateExportPassphrase(passphrase)
        try snapshot.validate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var plaintext = try encoder.encode(snapshot)
        defer {
            if !plaintext.isEmpty {
                plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex)
            }
        }

        let salt = try randomBytes(count: saltLength)
        var header = Data(capacity: headerLength)
        header.append(contentsOf: magic)
        header.append(containerVersion)
        header.append(kdfPBKDF2SHA256)
        var bigEndianIterations = defaultIterations.bigEndian
        withUnsafeBytes(of: &bigEndianIterations) { header.append(contentsOf: $0) }
        header.append(salt)
        precondition(header.count == headerLength)

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: defaultIterations)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
        guard sealed.tag.count == tagLength else { throw LedgerArchiveError.keyDerivationFailed }

        var archive = Data(capacity: headerLength + nonceLength + sealed.ciphertext.count + tagLength)
        archive.append(header)
        archive.append(contentsOf: nonce)
        archive.append(sealed.ciphertext)
        archive.append(sealed.tag)
        return archive
    }

    static func decrypt(_ data: Data, passphrase: String) throws -> LedgerSnapshot {
        guard !passphrase.isEmpty else { throw LedgerArchiveError.emptyPassphrase }
        guard passphrase.unicodeScalars.count <= maximumPassphraseLength else {
            throw LedgerArchiveError.decryptionFailed
        }
        guard data.count <= maximumArchiveBytes else { throw LedgerArchiveError.fileTooLarge }
        guard data.count >= headerLength + nonceLength + tagLength else {
            throw LedgerArchiveError.invalidFormat
        }

        let header = data.prefix(headerLength)
        guard Array(header.prefix(4)) == magic else {
            throw LedgerArchiveError.invalidFormat
        }
        let version = header[header.startIndex + 4]
        guard version == containerVersion else {
            throw version > containerVersion
                ? LedgerArchiveError.unsupportedArchiveVersion(Int(version))
                : LedgerArchiveError.invalidFormat
        }
        let kdf = header[header.startIndex + 5]
        guard kdf == kdfPBKDF2SHA256 else {
            throw LedgerArchiveError.invalidFormat
        }

        let iterStart = header.startIndex + 6
        let iterations: UInt32 = (UInt32(header[iterStart]) << 24)
            | (UInt32(header[iterStart + 1]) << 16)
            | (UInt32(header[iterStart + 2]) << 8)
            | UInt32(header[iterStart + 3])
        guard (minIterations...maxIterations).contains(iterations) else {
            throw LedgerArchiveError.invalidFormat
        }

        let salt = Data(header[(header.startIndex + 10)..<(header.startIndex + headerLength)])
        let nonceStart = data.startIndex + headerLength
        let ciphertextStart = nonceStart + nonceLength
        let tagStart = data.endIndex - tagLength
        guard ciphertextStart <= tagStart else { throw LedgerArchiveError.invalidFormat }

        let nonceData = data[nonceStart..<ciphertextStart]
        let ciphertext = data[ciphertextStart..<tagStart]
        let tag = data[tagStart..<data.endIndex]
        guard tag.count == tagLength else { throw LedgerArchiveError.invalidFormat }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        var plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw LedgerArchiveError.decryptionFailed
        }
        defer {
            if !plaintext.isEmpty {
                plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex)
            }
        }

        let snapshot: LedgerSnapshot
        do {
            snapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: plaintext)
        } catch {
            throw LedgerArchiveError.corruptedPayload
        }
        try snapshot.validate()
        return snapshot
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw LedgerArchiveError.keyDerivationFailed
        }
        return Data(bytes)
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var passwordBytes = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer {
            passwordBytes.resetBytes()
            derived.resetBytes()
        }

        let status: CCCryptorStatus = salt.withUnsafeBytes { saltBuffer in
            guard let saltBase = saltBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return CCCryptorStatus(kCCParamError)
            }
            return passwordBytes.withUnsafeBufferPointer { passBuffer in
                let passPtr = passBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr,
                    passBuffer.count,
                    saltBase,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw LedgerArchiveError.keyDerivationFailed
        }
        return SymmetricKey(data: derived)
    }
}

private extension Array where Element == UInt8 {
    mutating func resetBytes() {
        for i in indices { self[i] = 0 }
    }
}
