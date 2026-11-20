import Foundation

@MainActor
extension Store {
    /// Exports the local encrypted ledger into a single passphrase-encrypted `.cardledger` archive.
    /// PBKDF2 key derivation and AES-256-GCM encryption run off the main actor.
    func exportEncryptedArchive(passphrase: String) async throws -> Data {
        guard let repo else { throw DatabaseError.keyUnavailable }
        try LedgerArchive.validateExportPassphrase(passphrase)
        let snapshot = try repo.exportSnapshot()
        return try await Task.detached(priority: .userInitiated) {
            try LedgerArchive.encrypt(snapshot, passphrase: passphrase)
        }.value
    }

    /// Decrypts and validates an encrypted archive off the main actor without modifying the local ledger.
    func inspectEncryptedArchive(_ data: Data, passphrase: String) async throws -> LedgerSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try LedgerArchive.decrypt(data, passphrase: passphrase)
        }.value
    }

    /// Atomically replaces the local encrypted ledger with a previously decrypted and validated snapshot,
    /// reloads all persisted settings and data, and refreshes local notifications.
    func restoreArchive(_ snapshot: LedgerSnapshot) throws {
        guard let repo else { throw DatabaseError.keyUnavailable }
        guard !isSyncing && !isRefreshingBills else { throw LedgerArchiveError.syncInProgress }
        notReadyRetryTask?.cancel()
        notReadyRetryTask = nil
        try repo.restoreSnapshot(snapshot)
        pendingMappingConnectionID = nil
        billSetupAfterMappingID = nil
        reauthConnectionID = nil
        activityCardID = nil
        lastStatementAlertSignature = nil
        lastBenefitAlertSignature = nil
        syncMessage = nil
        billRefreshMessage = nil
        loadPersistedSettings(from: repo)
        reload()
        updateBillNotifications()
    }
}
