import Foundation

extension LedgerRepository {
    /// Reads every local SQLCipher table inside a single transaction for a consistent encrypted archive.
    func exportSnapshot(exportedAt: Date = Date()) throws -> LedgerSnapshot {
        try db.transaction {
            let schemaVersion = try db.userVersion()

            let connections = try db.query("SELECT * FROM connection ORDER BY id").map { r in
                LedgerSnapshot.ConnectionRow(
                    id: try requireString(r, "id"),
                    institution: try requireString(r, "institution"),
                    country: try requireString(r, "country"),
                    environment: try requireString(r, "environment"),
                    status: try requireString(r, "status"),
                    cursor: r["cursor"]?.string,
                    lastSync: r["last_sync"]?.string,
                    historyStatus: r["history_status"]?.string
                )
            }

            let cards = try db.query("SELECT * FROM card ORDER BY id").map { r in
                LedgerSnapshot.CardRow(
                    id: try requireString(r, "id"),
                    nickname: try requireString(r, "nickname"),
                    productId: try requireString(r, "product_id"),
                    mask: r["mask"]?.string,
                    openedOn: r["opened_on"]?.string,
                    renewalDate: r["renewal_date"]?.string,
                    renewalPrecision: r["renewal_precision"]?.string,
                    renewalSource: r["renewal_source"]?.string,
                    connectionId: r["connection_id"]?.string,
                    createdAt: try requireString(r, "created_at"),
                    isAU: r["is_au"]?.bool ?? false,
                    openedStatus: r["opened_status"]?.string
                )
            }

            let sourceAccounts = try db.query("SELECT * FROM source_account ORDER BY id").map { r in
                LedgerSnapshot.SourceAccountRow(
                    id: try requireString(r, "id"),
                    connectionId: try requireString(r, "connection_id"),
                    name: try requireString(r, "name"),
                    mask: r["mask"]?.string,
                    type: try requireString(r, "type"),
                    subtype: r["subtype"]?.string,
                    currency: r["currency"]?.string,
                    cardId: r["card_id"]?.string,
                    ignored: r["ignored"]?.bool ?? false
                )
            }

            let transactions = try db.query("SELECT * FROM txn ORDER BY id").map { r in
                LedgerSnapshot.TransactionRow(
                    id: try requireString(r, "id"),
                    cardId: try requireString(r, "card_id"),
                    provenance: try requireString(r, "provenance"),
                    sourceId: try requireString(r, "source_id"),
                    amountMinor: try requireInt64(r, "amount_minor"),
                    currency: r["currency"]?.string,
                    posted: try requireString(r, "posted"),
                    authorized: r["authorized"]?.string,
                    merchant: try requireString(r, "merchant"),
                    originalDescription: try requireString(r, "original_description"),
                    category: try requireString(r, "category"),
                    kind: try requireString(r, "kind"),
                    pending: r["pending"]?.bool ?? false,
                    mcc: r["mcc"]?.string
                )
            }

            let decisions = try db.query("SELECT * FROM decision ORDER BY credit_id").map { r in
                LedgerSnapshot.DecisionRow(
                    creditId: try requireString(r, "credit_id"),
                    kind: try requireString(r, "kind"),
                    periodId: r["period_id"]?.string,
                    decidedAt: try requireString(r, "decided_at")
                )
            }

            let categoryOverrides = try db.query("SELECT * FROM category_override ORDER BY txn_id").map { r in
                LedgerSnapshot.CategoryOverrideRow(
                    txnId: try requireString(r, "txn_id"),
                    category: try requireString(r, "category"),
                    editedAt: try requireString(r, "edited_at")
                )
            }

            let welcomeOffers = try db.query("SELECT * FROM welcome_offer ORDER BY id").map { r in
                LedgerSnapshot.WelcomeOfferRow(
                    id: try requireString(r, "id"),
                    cardId: try requireString(r, "card_id"),
                    kind: try requireString(r, "kind"),
                    start: try requireString(r, "start"),
                    months: Int(try requireInt64(r, "months")),
                    currency: try requireString(r, "currency"),
                    minSpendMinor: int64Value(r["min_spend_minor"]),
                    points: doubleValue(r["points"]),
                    cashMinor: int64Value(r["cash_minor"]),
                    extraMultiplier: doubleValue(r["extra_multiplier"]),
                    categories: r["categories"]?.string,
                    spendCapMinor: int64Value(r["spend_cap_minor"]),
                    notes: r["notes"]?.string,
                    earned: r["earned"]?.bool ?? false
                )
            }

            let benefitUsages = try db.query("SELECT * FROM benefit_usage ORDER BY id").map { r in
                LedgerSnapshot.BenefitUsageRow(
                    id: try requireString(r, "id"),
                    periodId: try requireString(r, "period_id"),
                    amountMinor: try requireInt64(r, "amount_minor"),
                    currency: try requireString(r, "currency"),
                    usedOn: try requireString(r, "used_on"),
                    note: r["note"]?.string,
                    loggedAt: try requireString(r, "logged_at")
                )
            }

            let awardCertificates = try db.query("SELECT * FROM award_certificate ORDER BY id").map { r in
                LedgerSnapshot.AwardCertificateRow(
                    id: try requireString(r, "id"),
                    cardId: try requireString(r, "card_id"),
                    ruleId: try requireString(r, "rule_id"),
                    issuedOn: try requireString(r, "issued_on"),
                    expiresOn: try requireString(r, "expires_on"),
                    redeemedOn: r["redeemed_on"]?.string,
                    note: r["note"]?.string
                )
            }

            let settings = try db.query("SELECT key, value FROM setting ORDER BY key").map { r in
                LedgerSnapshot.SettingRow(
                    key: try requireString(r, "key"),
                    value: try requireString(r, "value")
                )
            }

            let iso = ISO8601DateFormatter()
            return LedgerSnapshot(
                archiveVersion: LedgerArchive.currentArchiveVersion,
                schemaVersion: schemaVersion,
                exportedAt: iso.string(from: exportedAt),
                connections: connections,
                cards: cards,
                sourceAccounts: sourceAccounts,
                transactions: transactions,
                decisions: decisions,
                categoryOverrides: categoryOverrides,
                welcomeOffers: welcomeOffers,
                benefitUsages: benefitUsages,
                awardCertificates: awardCertificates,
                settings: settings
            )
        }
    }

    /// Replaces every local SQLCipher table from `snapshot` inside a single atomic transaction.
    /// Any validation or constraint error rolls back completely, leaving the existing ledger untouched.
    func restoreSnapshot(_ snapshot: LedgerSnapshot) throws {
        try snapshot.validate()

        try db.transaction {
            // Clear existing tables in reverse foreign-key dependency order.
            try db.run("DELETE FROM decision")
            try db.run("DELETE FROM category_override")
            try db.run("DELETE FROM txn")
            try db.run("DELETE FROM welcome_offer")
            try db.run("DELETE FROM award_certificate")
            try db.run("DELETE FROM benefit_usage")
            try db.run("DELETE FROM source_account")
            try db.run("DELETE FROM card")
            try db.run("DELETE FROM connection")
            try db.run("DELETE FROM setting")

            for c in snapshot.connections {
                try db.run("""
                    INSERT INTO connection(id, institution, country, environment, status, cursor, last_sync, history_status)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, [
                        c.id.sql, c.institution.sql, c.country.sql, c.environment.sql,
                        c.status.sql, c.cursor.sql, c.lastSync.sql, c.historyStatus.sql,
                    ])
            }

            for c in snapshot.cards {
                try db.run("""
                    INSERT INTO card(id, nickname, product_id, mask, opened_on, renewal_date, renewal_precision,
                      renewal_source, connection_id, created_at, is_au, opened_status)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                        c.id.sql, c.nickname.sql, c.productId.sql, c.mask.sql,
                        c.openedOn.sql, c.renewalDate.sql, c.renewalPrecision.sql, c.renewalSource.sql,
                        c.connectionId.sql, c.createdAt.sql, c.isAU.sql, c.openedStatus.sql,
                    ])
            }

            for a in snapshot.sourceAccounts {
                try db.run("""
                    INSERT INTO source_account(id, connection_id, name, mask, type, subtype, currency, card_id, ignored)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """, [
                        a.id.sql, a.connectionId.sql, a.name.sql, a.mask.sql,
                        a.type.sql, a.subtype.sql, a.currency.sql, a.cardId.sql, a.ignored.sql,
                    ])
            }

            for t in snapshot.transactions {
                try db.run("""
                    INSERT INTO txn(id, card_id, provenance, source_id, amount_minor, currency, posted, authorized,
                      merchant, original_description, category, kind, pending, mcc)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                        t.id.sql, t.cardId.sql, t.provenance.sql, t.sourceId.sql,
                        .int(t.amountMinor), t.currency.sql, t.posted.sql, t.authorized.sql,
                        t.merchant.sql, t.originalDescription.sql, t.category.sql, t.kind.sql,
                        t.pending.sql, t.mcc.sql,
                    ])
            }

            for d in snapshot.decisions {
                try db.run("""
                    INSERT INTO decision(credit_id, kind, period_id, decided_at)
                    VALUES(?,?,?,?)
                    """, [d.creditId.sql, d.kind.sql, d.periodId.sql, d.decidedAt.sql])
            }

            for o in snapshot.categoryOverrides {
                try db.run("""
                    INSERT INTO category_override(txn_id, category, edited_at)
                    VALUES(?,?,?)
                    """, [o.txnId.sql, o.category.sql, o.editedAt.sql])
            }

            for w in snapshot.welcomeOffers {
                try db.run("""
                    INSERT INTO welcome_offer(id, card_id, kind, start, months, currency, min_spend_minor, points,
                      cash_minor, extra_multiplier, categories, spend_cap_minor, notes, earned)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                        w.id.sql, w.cardId.sql, w.kind.sql, w.start.sql, w.months.sql, w.currency.sql,
                        w.minSpendMinor.map { .int($0) } ?? .null,
                        w.points.map { .real($0) } ?? .null,
                        w.cashMinor.map { .int($0) } ?? .null,
                        w.extraMultiplier.map { .real($0) } ?? .null,
                        w.categories.sql,
                        w.spendCapMinor.map { .int($0) } ?? .null,
                        w.notes.sql, w.earned.sql,
                    ])
            }

            for u in snapshot.benefitUsages {
                try db.run("""
                    INSERT INTO benefit_usage(id, period_id, amount_minor, currency, used_on, note, logged_at)
                    VALUES(?,?,?,?,?,?,?)
                    """, [
                        u.id.sql, u.periodId.sql, .int(u.amountMinor), u.currency.sql,
                        u.usedOn.sql, u.note.sql, u.loggedAt.sql,
                    ])
            }

            for c in snapshot.awardCertificates {
                try db.run("""
                    INSERT INTO award_certificate(id, card_id, rule_id, issued_on, expires_on, redeemed_on, note)
                    VALUES(?,?,?,?,?,?,?)
                    """, [
                        c.id.sql, c.cardId.sql, c.ruleId.sql, c.issuedOn.sql,
                        c.expiresOn.sql, c.redeemedOn.sql, c.note.sql,
                    ])
            }

            for s in snapshot.settings {
                try db.run("INSERT INTO setting(key, value) VALUES(?, ?)", [s.key.sql, s.value.sql])
            }

            // Fail closed if any foreign key is violated inside SQLite before committing.
            let fkViolations = try db.query("PRAGMA foreign_key_check;")
            guard fkViolations.isEmpty else {
                throw LedgerArchiveError.corruptedPayload
            }
        }

        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try? EncryptedDatabase.protect(db.url.deletingLastPathComponent())
    }

    private func requireString(_ row: Row, _ column: String) throws -> String {
        guard let value = row[column]?.string else {
            throw LedgerArchiveError.corruptedPayload
        }
        return value
    }

    private func requireInt64(_ row: Row, _ column: String) throws -> Int64 {
        guard let value = int64Value(row[column]) else {
            throw LedgerArchiveError.corruptedPayload
        }
        return value
    }

    private func int64Value(_ value: SQLValue?) -> Int64? {
        if case .int(let v) = value { return v }
        return nil
    }

    private func doubleValue(_ value: SQLValue?) -> Double? {
        if case .real(let d) = value { return d }
        if case .int(let i) = value { return Double(i) }
        return nil
    }
}
