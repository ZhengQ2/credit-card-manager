import XCTest
@testable import CardLedger

final class LedgerArchiveTests: XCTestCase {
    private let passphrase = "correct-horse-battery-staple"

    private func makeTempRepository() throws -> (directory: URL, repo: LedgerRepository) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cl-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try EncryptedDatabase(directory: dir)
        let repo = try LedgerRepository(db: db)
        return (dir, repo)
    }

    private func populateAllTables(in repo: LedgerRepository) throws -> (linkedCardID: String, manualCardID: String) {
        // 1. Connections & source accounts (one mapped credit card, one hidden account)
        let conn = StoredConnection(
            id: "conn-1",
            institution: "Synthetic Bank",
            country: "CA",
            environment: "mock",
            status: "active",
            cursor: #"{"acc-1":"cur-42"}"#,
            lastSync: Date(timeIntervalSince1970: 1_795_000_000),
            historyStatus: "COMPLETE"
        )
        let mappedAcc = SourceAccount(
            id: "acc-1", connectionID: "conn-1", name: "Platinum Card", mask: "10088",
            type: "credit", subtype: "credit card", currency: "CAD", cardID: nil, ignored: false
        )
        let hiddenAcc = SourceAccount(
            id: "acc-2", connectionID: "conn-1", name: "Extra Card", mask: "2004",
            type: "credit", subtype: "credit card", currency: "CAD", cardID: nil, ignored: false
        )
        try repo.saveConnection(conn, accounts: [mappedAcc, hiddenAcc])
        try repo.confirmMapping(connection: "conn-1", [(account: mappedAcc, productID: "amex-cobalt-ca", nickname: "My Cobalt")])
        try repo.setIgnored(true, accounts: ["acc-2"])
        try repo.setHistoryStatus("COMPLETE", connection: "conn-1")

        // 2. Second (manual) card with explicit open date and renewal date
        try repo.createManualCard(
            nickname: "Home Trust Visa",
            productID: "home-trust-preferred-ca",
            mask: "4321",
            openedOn: Day.make(2024, 3, 15),
            renewal: Day.make(2027, 3, 15)
        )

        let cards = try repo.loadCards()
        let linkedCardID = try XCTUnwrap(cards.first(where: { $0.connectionID == "conn-1" })?.id)
        let manualCardID = try XCTUnwrap(cards.first(where: { $0.connectionID == nil })?.id)

        try repo.setOpenDate(cardID: linkedCardID, date: Day.make(2025, 1, 10), status: .confirmed)
        try repo.setRenewal(cardID: linkedCardID, date: Day.make(2027, 1, 10), precision: .day, source: .owner)

        // 3. Transactions via Plaid sync batch + PDF/CSV import (covering purchases, refunds, credits, fees, offers, MCC, pending)
        let syncBatch = SyncBatch(
            pages: [
                SyncPageDelta(
                    added: [
                        RemoteTransaction(
                            id: "plaid-tx-1", accountId: "acc-1", amountMinor: 4250, currency: "CAD",
                            currencyIsOfficial: true, date: "2026-10-05", authorizedDate: "2026-10-04",
                            name: "METRO PLUS", merchantName: "Metro", originalDescription: "METRO PLUS TORONTO ON",
                            categoryPrimary: "FOOD_AND_DRINK", categoryDetailed: "FOOD_AND_DRINK_GROCERIES",
                            merchantCategoryCode: "5411", pending: false, pendingTransactionId: nil
                        ),
                        RemoteTransaction(
                            id: "plaid-tx-2", accountId: "acc-1", amountMinor: -1500, currency: "CAD",
                            currencyIsOfficial: true, date: "2026-10-08", authorizedDate: nil,
                            name: "STATEMENT CREDIT", merchantName: nil, originalDescription: "AMEX STATEMENT CREDIT",
                            categoryPrimary: "INCOME", categoryDetailed: "INCOME_OTHER_INCOME",
                            merchantCategoryCode: nil, pending: false, pendingTransactionId: nil
                        ),
                        RemoteTransaction(
                            id: "plaid-tx-3", accountId: "acc-1", amountMinor: 1299, currency: "CAD",
                            currencyIsOfficial: true, date: "2026-11-18", authorizedDate: "2026-11-18",
                            name: "COFFEE SHOP", merchantName: "Coffee Shop", originalDescription: "COFFEE SHOP PENDING",
                            categoryPrimary: "FOOD_AND_DRINK", categoryDetailed: "FOOD_AND_DRINK_COFFEE",
                            merchantCategoryCode: "5812", pending: true, pendingTransactionId: nil
                        ),
                    ],
                    modified: [],
                    removed: []
                )
            ],
            historyStatus: "COMPLETE"
        )
        try repo.apply(syncBatch, connection: "conn-1", cursor: #"{"acc-1":"cur-42"}"#)

        let pdfRow = ParsedPDFTransaction(
            id: "pdf-1",
            posted: Day.make(2026, 11, 2),
            authorized: Day.make(2026, 11, 1),
            merchant: "Shop Small Merchant",
            originalDescription: "SHOP SMALL OFFER CREDIT",
            amount: Money(-500, .cad),
            category: .other,
            kind: .offerCredit,
            rawLine: "02 Nov 2026 SHOP SMALL OFFER CREDIT -5.00",
            page: 1,
            provenance: .pdf,
            sourceKey: "REF-OFFER-1",
            offerTag: "ShopSmallOffer"
        )
        try repo.importPDFTransactions([pdfRow], cardID: manualCardID)

        let txns = try repo.loadTransactions()
        let purchaseID = try XCTUnwrap(txns.first(where: { $0.kind == .purchase && !$0.pending })?.id)
        let creditID = try XCTUnwrap(txns.first(where: { $0.kind == .issuerCredit })?.id)

        // 4. Decisions & category overrides
        try repo.saveDecision(creditID, .assign(periodID: "rule-1|\(linkedCardID)|2026-10-01"))
        try repo.saveCategoryOverride(purchaseID, .dining)

        // 5. Welcome offers, benefit usage logs, award certificates
        let offer = WelcomeOffer(
            id: "offer-1",
            cardID: linkedCardID,
            kind: .spendBonus,
            currency: .cad,
            start: Day.make(2026, 1, 10),
            months: 6,
            minSpend: Money(300_000, .cad),
            points: 30_000,
            cash: nil,
            extraMultiplier: 2.5,
            categories: [.dining, .groceries],
            spendCap: Money(500_000, .cad),
            notes: "Synthetic welcome offer",
            markedEarned: false
        )
        try repo.saveWelcomeOffer(offer, currency: .cad)

        let usage = UsageLog(
            id: "usage-1",
            periodID: "app-credit|\(linkedCardID)|2026-11-01",
            amount: Money(1500, .cad),
            usedOn: Day.make(2026, 11, 5),
            note: "Used Uber Cash"
        )
        try repo.addUsage(usage)

        let cert = AwardCertificate(
            id: "cert-1",
            cardID: linkedCardID,
            ruleID: "free-night",
            issuedOn: Day.make(2026, 2, 1),
            expiresOn: Day.make(2027, 2, 1),
            redeemedOn: nil,
            note: "35k certificate"
        )
        try repo.saveCertificate(cert)

        // 6. Settings (assumptions, pins, reminder offsets, statement bill, membership, device lock, fee toggle)
        var assumptions = Assumptions()
        assumptions.cadPerUSD = 1.41
        assumptions.centsPerPoint["amex-mr-ca"] = 2.2
        try repo.setSetting("assumptions", String(decoding: try JSONEncoder().encode(assumptions), as: UTF8.self))
        try repo.setSetting("pinned_card", String(decoding: try JSONEncoder().encode(["dining": linkedCardID]), as: UTF8.self))
        try repo.setSetting("reminder_offsets", String(decoding: try JSONEncoder().encode([14, 2]), as: UTF8.self))
        try repo.setSetting("require_device_auth", "1")
        try repo.setSetting("count_offers_in_fee", "0")
        try repo.setSetting("membership.\(linkedCardID).priority-pass", "2026-03-01")
        try repo.saveStatementBill(
            StatementBill(cardID: manualCardID, dueDate: Day.make(2026, 12, 12), statementDate: Day.make(2026, 11, 18), source: .pdf),
            cardID: manualCardID
        )

        return (linkedCardID, manualCardID)
    }

    func testFullExportRestoreAndExactComparisonAcrossAllTables() throws {
        let source = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let (linkedCardID, manualCardID) = try populateAllTables(in: source.repo)

        let exportedSnapshot = try source.repo.exportSnapshot(exportedAt: Date(timeIntervalSince1970: 1_795_100_000))
        XCTAssertEqual(exportedSnapshot.schemaVersion, LedgerArchive.currentSchemaVersion)
        let archiveBytes = try LedgerArchive.encrypt(exportedSnapshot, passphrase: passphrase)

        // Confirm encrypted bytes do not leak plaintext ledger data.
        let rawText = String(decoding: archiveBytes, as: UTF8.self)
        XCTAssertFalse(rawText.contains("METRO PLUS"))
        XCTAssertFalse(rawText.contains("My Cobalt"))
        XCTAssertFalse(rawText.contains("Home Trust Visa"))
        XCTAssertFalse(rawText.contains("Synthetic welcome offer"))

        // Simulate a fresh install (even with unrelated existing rows that must be replaced cleanly).
        let target = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: target.directory) }
        try target.repo.createManualCard(
            nickname: "Old Card To Replace",
            productID: "custom-us",
            mask: "9999",
            openedOn: Day.make(2020, 1, 1),
            renewal: nil
        )
        try target.repo.setSetting("stale_key", "stale_value")

        let decrypted = try LedgerArchive.decrypt(archiveBytes, passphrase: passphrase)
        XCTAssertEqual(decrypted, exportedSnapshot)

        try target.repo.restoreSnapshot(decrypted)
        let restoredSnapshot = try target.repo.exportSnapshot(exportedAt: Date(timeIntervalSince1970: 1_795_100_000))

        // Full row-by-row equality across all 10 tables.
        XCTAssertEqual(restoredSnapshot, exportedSnapshot)

        // Verify high-level repository reads match too.
        XCTAssertEqual(try target.repo.loadCards().map(\.id).sorted(), [linkedCardID, manualCardID].sorted())
        XCTAssertEqual(try target.repo.loadTransactions().count, 4)
        XCTAssertEqual(try target.repo.decisions().count, 1)
        XCTAssertEqual(try target.repo.categoryOverrides().count, 1)
        XCTAssertEqual(try target.repo.welcomeOffers().first?.points, 30_000)
        XCTAssertEqual(try target.repo.usageLogs().first?.note, "Used Uber Cash")
        XCTAssertEqual(try target.repo.certificates().first?.note, "35k certificate")
        XCTAssertEqual(try target.repo.statementBills()[manualCardID]?.dueDate, Day.make(2026, 12, 12))
        XCTAssertEqual(target.repo.setting("require_device_auth"), "1")
        XCTAssertEqual(target.repo.setting("count_offers_in_fee"), "0")
        XCTAssertNil(target.repo.setting("stale_key"))
    }

    func testWrongPassphraseRejectedWithoutChangingLedger() throws {
        let source = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        _ = try populateAllTables(in: source.repo)
        let archiveBytes = try LedgerArchive.encrypt(try source.repo.exportSnapshot(), passphrase: passphrase)

        let target = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: target.directory) }
        try target.repo.createManualCard(
            nickname: "Existing Card",
            productID: "custom-ca",
            mask: "1111",
            openedOn: Day.make(2025, 5, 1),
            renewal: nil
        )
        let before = try target.repo.exportSnapshot(exportedAt: Date(timeIntervalSince1970: 1_795_100_000))

        XCTAssertThrowsError(try LedgerArchive.decrypt(archiveBytes, passphrase: "wrong-passphrase-1234")) { error in
            XCTAssertEqual(error as? LedgerArchiveError, .decryptionFailed)
        }

        let after = try target.repo.exportSnapshot(exportedAt: Date(timeIntervalSince1970: 1_795_100_000))
        XCTAssertEqual(after, before, "Failed decrypt must leave the target ledger untouched")
    }

    func testDamagedOrTamperedArchiveRejectedWithoutChangingLedger() throws {
        let source = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        _ = try populateAllTables(in: source.repo)
        let validArchive = try LedgerArchive.encrypt(try source.repo.exportSnapshot(), passphrase: passphrase)

        // 1. Truncated & invalid magic
        XCTAssertThrowsError(try LedgerArchive.decrypt(Data("CLBK".utf8), passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .invalidFormat)
        }
        var badMagic = validArchive
        badMagic[0] ^= 0xFF
        XCTAssertThrowsError(try LedgerArchive.decrypt(badMagic, passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .invalidFormat)
        }

        // 2. Unsupported future container version and invalid version 0
        var futureVersion = validArchive
        futureVersion[4] = 99
        XCTAssertThrowsError(try LedgerArchive.decrypt(futureVersion, passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .unsupportedArchiveVersion(99))
        }
        var zeroVersion = validArchive
        zeroVersion[4] = 0
        XCTAssertThrowsError(try LedgerArchive.decrypt(zeroVersion, passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .invalidFormat)
        }

        // 3. Tampered header salt (bound via AAD)
        var tamperedSalt = validArchive
        tamperedSalt[15] ^= 0x01
        XCTAssertThrowsError(try LedgerArchive.decrypt(tamperedSalt, passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .decryptionFailed)
        }

        // 4. Tampered nonce
        var tamperedNonce = validArchive
        tamperedNonce[44] ^= 0x01
        XCTAssertThrowsError(try LedgerArchive.decrypt(tamperedNonce, passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .decryptionFailed)
        }

        // 5. Tampered ciphertext byte
        var tamperedCipher = validArchive
        tamperedCipher[60] ^= 0x01
        XCTAssertThrowsError(try LedgerArchive.decrypt(tamperedCipher, passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .decryptionFailed)
        }

        // 6. Tampered GCM authentication tag
        var tamperedTag = validArchive
        tamperedTag[tamperedTag.count - 1] ^= 0x01
        XCTAssertThrowsError(try LedgerArchive.decrypt(tamperedTag, passphrase: passphrase)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .decryptionFailed)
        }

        // 7. Corrupted snapshot with broken foreign key rolls back cleanly and preserves existing ledger
        let target = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: target.directory) }
        try target.repo.createManualCard(
            nickname: "Keep Me Safe",
            productID: "custom-ca",
            mask: "2222",
            openedOn: Day.make(2025, 6, 1),
            renewal: nil
        )
        let before = try target.repo.exportSnapshot(exportedAt: Date(timeIntervalSince1970: 1_795_100_000))

        let brokenSnapshot = LedgerSnapshot(
            archiveVersion: LedgerArchive.currentArchiveVersion,
            schemaVersion: LedgerArchive.currentSchemaVersion,
            exportedAt: "2026-11-19T00:00:00Z",
            connections: [],
            cards: [],
            sourceAccounts: [],
            transactions: [
                LedgerSnapshot.TransactionRow(
                    id: "orphan-tx", cardId: "nonexistent-card", provenance: "PDF statement",
                    sourceId: "pdf:orphan", amountMinor: 1000, currency: "CAD",
                    posted: "2026-11-01", authorized: nil, merchant: "Orphan",
                    originalDescription: "ORPHAN", category: "other", kind: "purchase",
                    pending: false, mcc: nil
                )
            ],
            decisions: [],
            categoryOverrides: [],
            welcomeOffers: [],
            benefitUsages: [],
            awardCertificates: [],
            settings: []
        )
        XCTAssertThrowsError(try target.repo.restoreSnapshot(brokenSnapshot)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .corruptedPayload)
        }
        let after = try target.repo.exportSnapshot(exportedAt: Date(timeIntervalSince1970: 1_795_100_000))
        XCTAssertEqual(after, before, "Rejected snapshot must not modify the existing ledger")
    }

    func testPassphraseInEitherUnicodeFormUnlocksTheSameArchive() throws {
        let source = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        _ = try populateAllTables(in: source.repo)
        let snap = try source.repo.exportSnapshot()

        // "café crème brûlée", with each accented letter as one code point, then as a letter plus a combining mark.
        let composed = "caf\u{00E9} cr\u{00E8}me br\u{00FB}l\u{00E9}e"
        let decomposed = "cafe\u{0301} cre\u{0300}me bru\u{0302}le\u{0301}e"
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8), "The fixture must differ byte for byte")

        let archive = try LedgerArchive.encrypt(snap, passphrase: composed)
        XCTAssertEqual(try LedgerArchive.decrypt(archive, passphrase: decomposed), snap)
        let reverse = try LedgerArchive.encrypt(snap, passphrase: decomposed)
        XCTAssertEqual(try LedgerArchive.decrypt(reverse, passphrase: composed), snap)

        // Length limits count characters after normalization, so combining marks don't pad a short passphrase.
        let elevenDecomposed = "e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}abcde"
        XCTAssertEqual(LedgerArchive.passphraseLength(elevenDecomposed), 11)
        XCTAssertThrowsError(try LedgerArchive.encrypt(snap, passphrase: elevenDecomposed)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .passphraseTooShort(minimum: LedgerArchive.minimumPassphraseLength))
        }
    }

    func testPassphraseMinimumLengthAndRandomSaltsEnforced() throws {
        let source = try makeTempRepository()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let snap = try source.repo.exportSnapshot()

        XCTAssertThrowsError(try LedgerArchive.encrypt(snap, passphrase: "too-short")) {
            XCTAssertEqual($0 as? LedgerArchiveError, .passphraseTooShort(minimum: LedgerArchive.minimumPassphraseLength))
        }

        let first = try LedgerArchive.encrypt(snap, passphrase: passphrase)
        let second = try LedgerArchive.encrypt(snap, passphrase: passphrase)
        XCTAssertNotEqual(first, second, "Each export must generate a fresh random salt and nonce")
    }

    @MainActor
    func testStoreExportAndRestoreOnFreshInstallReloadsAllSettingsAndData() async throws {
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("cl-store-src-\(UUID().uuidString)", isDirectory: true)
        let targetDir = FileManager.default.temporaryDirectory.appendingPathComponent("cl-store-dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: targetDir)
        }

        let sourceStore = Store(today: Day.make(2026, 11, 19), databaseDirectory: sourceDir)
        let sourceRepo = try XCTUnwrap(sourceStore.repo)
        let (linkedCardID, manualCardID) = try populateAllTables(in: sourceRepo)
        sourceStore.loadPersistedSettings(from: sourceRepo)
        sourceStore.reload()
        XCTAssertEqual(sourceStore.mode, .live)

        let archiveBytes = try await sourceStore.exportEncryptedArchive(passphrase: passphrase)

        // Fresh install starts in sample mode with default settings.
        let freshStore = Store(today: Day.make(2026, 11, 19), databaseDirectory: targetDir)
        XCTAssertEqual(freshStore.mode, .sample)
        freshStore.pinnedCard[.gas] = "stale-sample-pin"
        freshStore.pendingMappingConnectionID = "stale-conn"
        freshStore.activityCardID = "stale-card"

        // Decrypt and verify sync/bill-refresh guards before restoring.
        let unlocked = try await freshStore.inspectEncryptedArchive(archiveBytes, passphrase: passphrase)
        XCTAssertEqual(unlocked.summary.cardCount, 2)
        XCTAssertEqual(unlocked.summary.transactionCount, 4)
        XCTAssertEqual(unlocked.summary.decisionCount, 1)
        XCTAssertEqual(unlocked.summary.overrideCount, 1)

        freshStore.isSyncing = true
        XCTAssertThrowsError(try freshStore.restoreArchive(unlocked)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .syncInProgress)
        }
        XCTAssertEqual(freshStore.mode, .sample, "Rejected restore during sync must leave sample mode untouched")
        freshStore.isSyncing = false

        freshStore.isRefreshingBills = true
        XCTAssertThrowsError(try freshStore.restoreArchive(unlocked)) {
            XCTAssertEqual($0 as? LedgerArchiveError, .syncInProgress)
        }
        freshStore.isRefreshingBills = false

        try freshStore.restoreArchive(unlocked)
        XCTAssertEqual(freshStore.mode, .live)
        XCTAssertNil(freshStore.pendingMappingConnectionID)
        XCTAssertNil(freshStore.activityCardID)
        XCTAssertEqual(Set(freshStore.cards.map(\.id)), Set([linkedCardID, manualCardID]))
        XCTAssertEqual(freshStore.transactions.count, 4)
        XCTAssertEqual(freshStore.decisions.count, 1)
        XCTAssertEqual(freshStore.categoryOverrides.count, 1)
        XCTAssertEqual(freshStore.welcomeOffers.count, 1)
        XCTAssertEqual(freshStore.usageLogs.count, 1)
        XCTAssertEqual(freshStore.certificates.count, 1)
        XCTAssertEqual(freshStore.statementBills[manualCardID]?.dueDate, Day.make(2026, 12, 12))
        XCTAssertEqual(freshStore.assumptions.cadPerUSD, 1.41, accuracy: 0.001)
        XCTAssertEqual(freshStore.assumptions.centsPerPoint["amex-mr-ca"], 2.2)
        XCTAssertEqual(freshStore.pinnedCard, [.dining: linkedCardID], "Stale pins must be cleared on restore")
        XCTAssertEqual(freshStore.reminderOffsets, [14, 2])
        XCTAssertTrue(freshStore.requireDeviceAuth)
        XCTAssertFalse(freshStore.countOffersInFee)
    }
}
