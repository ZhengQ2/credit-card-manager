import Foundation

struct StoredConnection: Identifiable, Hashable {
    let id: String
    var institution: String
    var country: String
    var environment: String
    /// active | login_required | disconnect_pending | disconnected
    var status: String
    var cursor: String?
    var lastSync: Date?
    var historyStatus: String?
}

struct SourceAccount: Identifiable, Hashable {
    let id: String
    let connectionID: String
    var name: String
    var mask: String?
    var type: String
    var subtype: String?
    var currency: String?
    var cardID: String?
    var ignored: Bool = false

    var isCreditCard: Bool { type == "credit" && (subtype == nil || subtype == "credit card") }
    var needsMapping: Bool { isCreditCard && cardID == nil && !ignored }
}

/// Changes staged from one page of a sync batch.
struct SyncPageDelta {
    var added: [RemoteTransaction] = []
    var modified: [RemoteTransaction] = []
    var removed: [String] = []
}

/// Changes staged from every page of one sync batch, applied atomically in page order with the new cursor (design §7).
struct SyncBatch {
    var pages: [SyncPageDelta] = []
    var historyStatus: String?
}

struct SyncApplyResult { var inserted = 0; var updated = 0; var removed = 0; var skippedUnmapped = 0 }

final class LedgerRepository {
    let db: EncryptedDatabase
    private let iso = ISO8601DateFormatter()

    init(db: EncryptedDatabase) throws {
        self.db = db
        try migrate()
    }

    private func migrate() throws {
        try migrateV1()
        if try db.userVersion() < 2 {
            try db.transaction {
                // Accounts the owner chose not to track (or whose card was deleted) stop showing as "to map".
                try db.exec("ALTER TABLE source_account ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0;")
                try db.setUserVersion(2)
            }
        }
        if try db.userVersion() < 3 {
            try db.transaction {
                // Reclassify balance adjustments synced before PlaidMapping learned to recognize them.
                try db.exec("""
                    UPDATE txn SET kind = 'payment' WHERE kind IN ('issuerCredit', 'refund') AND (
                      upper(original_description) LIKE '%REFUND CHECK%' OR upper(original_description) LIKE '%CR BAL%' OR
                      upper(original_description) LIKE '%CREDIT BALANCE%' OR upper(original_description) LIKE '%BALANCE REFUND%');
                    """)
                try db.setUserVersion(3)
            }
        }
        if try db.userVersion() < 4 {
            try db.transaction {
                try db.exec("""
                    ALTER TABLE card ADD COLUMN opened_status TEXT;
                    CREATE TABLE welcome_offer (
                      id TEXT PRIMARY KEY, card_id TEXT NOT NULL REFERENCES card(id) ON DELETE CASCADE,
                      kind TEXT NOT NULL, start TEXT NOT NULL, months INTEGER NOT NULL, currency TEXT NOT NULL,
                      min_spend_minor INTEGER, points REAL, cash_minor INTEGER, extra_multiplier REAL,
                      categories TEXT, spend_cap_minor INTEGER, notes TEXT, earned INTEGER NOT NULL DEFAULT 0);
                    """)
                try db.setUserVersion(4)
            }
        }
        if try db.userVersion() < 5 {
            try db.transaction {
                // Issuer reimbursements synced before they were recognized were stored as merchant refunds.
                try db.exec("""
                    UPDATE txn SET kind = 'issuerCredit' WHERE kind = 'refund' AND amount_minor < 0 AND (
                      upper(original_description) LIKE '%REIMBURSEMENT%' OR upper(original_description) LIKE '%STATEMENT CREDIT%');
                    """)
                try db.setUserVersion(5)
            }
        }
        if try db.userVersion() < 6 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE benefit_usage (
                      id TEXT PRIMARY KEY, period_id TEXT NOT NULL, amount_minor INTEGER NOT NULL, currency TEXT NOT NULL,
                      used_on TEXT NOT NULL, note TEXT, logged_at TEXT NOT NULL);
                    CREATE INDEX benefit_usage_period ON benefit_usage(period_id);
                    CREATE TABLE award_certificate (
                      id TEXT PRIMARY KEY, card_id TEXT NOT NULL REFERENCES card(id) ON DELETE CASCADE, rule_id TEXT NOT NULL,
                      issued_on TEXT NOT NULL, expires_on TEXT NOT NULL, redeemed_on TEXT, note TEXT);
                    """)
                try db.setUserVersion(6)
            }
        }
        if try db.userVersion() < 7 {
            try db.transaction {
                // Fix rows classified before fee/credit wording was understood:
                // credits Plaid filed under bank fees, balance adjustments, and Amex "RENEWAL MEMBERSHIP FEE" charges.
                try db.exec("""
                    UPDATE txn SET kind = 'payment' WHERE
                      upper(original_description) LIKE '%ADJ FOR BAL%' OR upper(original_description) LIKE '%ADJUSTMENT FOR BAL%';
                    UPDATE txn SET kind = 'issuerCredit' WHERE kind = 'fee' AND amount_minor < 0 AND (
                      upper(original_description) LIKE '%REIMBURSEMENT%' OR upper(original_description) LIKE '%CREDIT%');
                    UPDATE txn SET kind = 'refund' WHERE kind = 'fee' AND amount_minor < 0;
                    UPDATE txn SET kind = 'fee' WHERE kind = 'purchase' AND amount_minor > 0
                      AND (upper(original_description) LIKE '%ANNUAL FEE%' OR upper(original_description) LIKE '%ANNUAL MEMBERSHIP FEE%'
                           OR upper(original_description) LIKE '%RENEWAL MEMBERSHIP FEE%' OR upper(original_description) LIKE '%RENEWAL FEE%'
                           OR upper(original_description) LIKE '%ANNUAL CARD FEE%');
                    """)
                try db.setUserVersion(7)
            }
        }
        if try db.userVersion() < 8 {
            try db.transaction {
                // Reclassify issuer credits synced when Plaid populated merchant_name with a non-INCOME category.
                try db.exec("""
                    UPDATE txn SET kind = 'issuerCredit' WHERE kind = 'refund' AND amount_minor < 0 AND (
                      upper(original_description) LIKE '%REIMBURSEMENT%' OR upper(original_description) LIKE '%STATEMENT CREDIT%'
                      OR upper(original_description) LIKE '%REBATE%');
                    """)
                try db.setUserVersion(8)
            }
        }
        if try db.userVersion() < 9 {
            try db.transaction {
                // Monthly card fees (Amex Canada "MEMBERSHIP FEE INSTALLMENT") were synced as purchases.
                try db.exec("""
                    UPDATE txn SET kind = 'fee' WHERE kind = 'purchase' AND amount_minor > 0 AND (
                      upper(original_description) LIKE '%MEMBERSHIP FEE INSTALLMENT%' OR upper(original_description) LIKE '%MEMBERSHIP FEE INSTALMENT%'
                      OR upper(original_description) LIKE '%MONTHLY CARD FEE%');
                    """)
                try db.setUserVersion(9)
            }
        }
        if try db.userVersion() < 10 {
            try db.transaction {
                // Fee wording is matched by regex (PlaidMapping.isAnnualFee / isCardFee), which SQLite can't
                // evaluate, so narrow the rows in SQL and apply the same rules here.
                let rows = try db.query("""
                    SELECT id, original_description FROM txn WHERE kind = 'purchase' AND amount_minor > 0 AND (
                      upper(original_description) LIKE '%FEE%' OR upper(original_description) LIKE '%FRAIS%'
                      OR upper(original_description) LIKE '%COTISATION%');
                    """)
                for row in rows {
                    guard let id = row["id"]?.string, let text = row["original_description"]?.string?.uppercased(),
                          PlaidMapping.isAnnualFee(text) || PlaidMapping.isCardFee(text) else { continue }
                    try db.run("UPDATE txn SET kind = 'fee' WHERE id = ?", [.text(id)])
                }
                try db.setUserVersion(10)
            }
        }
        if try db.userVersion() < 11 {
            try db.transaction {
                // Re-classify existing purchases and refunds using the expanded ISO 18245 MCC directory.
                // Owner category overrides live in `category_override` and stay untouched.
                let rows = try db.query("""
                    SELECT id, mcc, category FROM txn
                    WHERE mcc IS NOT NULL AND mcc != '' AND kind IN ('purchase', 'refund');
                    """)
                for row in rows {
                    guard let id = row["id"]?.string,
                          let mapped = MCCDirectory.category(forCode: row["mcc"]?.string),
                          mapped.rawValue != row["category"]?.string else { continue }
                    try db.run("UPDATE txn SET category = ? WHERE id = ?", [mapped.rawValue.sql, id.sql])
                }
                try db.setUserVersion(11)
            }
        }
        if try db.userVersion() < 12 {
            try db.transaction {
                let rows = try db.query("""
                    SELECT id, merchant, original_description FROM txn
                    WHERE kind IN ('refund', 'issuerCredit') AND amount_minor < 0 AND provenance = 'Plaid'
                      AND (upper(original_description) LIKE '%HOTEL%CREDIT%' OR upper(merchant) LIKE '%HOTEL%CREDIT%');
                    """)
                for row in rows {
                    guard let id = row["id"]?.string, let original = row["original_description"]?.string,
                          let merchant = row["merchant"]?.string else { continue }
                    let description = PlaidMapping.hotelCreditDescription(original, alternate: merchant)
                    guard PlaidMapping.isAmexHotelCredit(description) else { continue }
                    try db.run("UPDATE txn SET kind = 'issuerCredit', original_description = ? WHERE id = ?",
                               [description.sql, id.sql])
                }
                try db.setUserVersion(12)
            }
        }
    }

    private func migrateV1() throws {
        guard try db.userVersion() < 1 else { return }
        try db.transaction {
            try db.exec("""
            CREATE TABLE connection (
              id TEXT PRIMARY KEY, institution TEXT NOT NULL, country TEXT NOT NULL, environment TEXT NOT NULL,
              status TEXT NOT NULL, cursor TEXT, last_sync TEXT, history_status TEXT);
            CREATE TABLE card (
              id TEXT PRIMARY KEY, nickname TEXT NOT NULL, product_id TEXT NOT NULL, mask TEXT,
              opened_on TEXT, renewal_date TEXT, renewal_precision TEXT, renewal_source TEXT,
              connection_id TEXT REFERENCES connection(id), created_at TEXT NOT NULL, is_au INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE source_account (
              id TEXT PRIMARY KEY, connection_id TEXT NOT NULL REFERENCES connection(id) ON DELETE CASCADE,
              name TEXT NOT NULL, mask TEXT, type TEXT NOT NULL, subtype TEXT, currency TEXT,
              card_id TEXT REFERENCES card(id) ON DELETE SET NULL);
            CREATE TABLE txn (
              id TEXT PRIMARY KEY, card_id TEXT NOT NULL REFERENCES card(id) ON DELETE CASCADE,
              provenance TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE,
              amount_minor INTEGER NOT NULL, currency TEXT, posted TEXT NOT NULL, authorized TEXT,
              merchant TEXT NOT NULL, original_description TEXT NOT NULL, category TEXT NOT NULL, kind TEXT NOT NULL,
              pending INTEGER NOT NULL, mcc TEXT);
            CREATE INDEX txn_card ON txn(card_id, posted);
            CREATE TABLE decision (credit_id TEXT PRIMARY KEY, kind TEXT NOT NULL, period_id TEXT, decided_at TEXT NOT NULL);
            CREATE TABLE category_override (txn_id TEXT PRIMARY KEY, category TEXT NOT NULL, edited_at TEXT NOT NULL);
            CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            try db.setUserVersion(1)
        }
    }

    // MARK: - Settings

    func setting(_ key: String) -> String? {
        (try? db.query("SELECT value FROM setting WHERE key = ?", [key.sql]).first?["value"]?.string) ?? nil
    }

    func setSetting(_ key: String, _ value: String?) throws {
        if let value { try db.run("INSERT INTO setting(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key.sql, value.sql]) }
        else { try db.run("DELETE FROM setting WHERE key = ?", [key.sql]) }
    }

    func settings(prefix: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for r in try db.query("SELECT key, value FROM setting WHERE key LIKE ?", ["\(prefix)%".sql]) {
            if let k = r["key"]?.string, let v = r["value"]?.string { out[k] = v }
        }
        return out
    }

    func billReport(connectionID: String) -> BillReport? {
        guard let raw = setting("bill_report.\(connectionID)") else { return nil }
        return try? JSONDecoder().decode(BillReport.self, from: Data(raw.utf8))
    }

    func saveBillReport(_ report: BillReport?, connectionID: String) throws {
        let value = try report.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try setSetting("bill_report.\(connectionID)", value)
    }

    func clearBillReports() throws { try db.run("DELETE FROM setting WHERE key GLOB 'bill_report.*'") }

    // MARK: - Connections and accounts

    func dropUnmappedNonCardAccounts() throws {
        try db.run("""
            DELETE FROM source_account WHERE card_id IS NULL
            AND (type != 'credit' OR (subtype IS NOT NULL AND subtype != 'credit card'))
            """)
    }

    func connections() throws -> [StoredConnection] {
        try db.query("SELECT * FROM connection ORDER BY institution").map { r in
            StoredConnection(id: r["id"]!.string!, institution: r["institution"]!.string!, country: r["country"]!.string!,
                             environment: r["environment"]!.string!, status: r["status"]!.string!,
                             cursor: r["cursor"]?.string, lastSync: r["last_sync"]?.string.flatMap { iso.date(from: $0) },
                             historyStatus: r["history_status"]?.string)
        }
    }

    func connection(_ id: String) throws -> StoredConnection? { try connections().first { $0.id == id } }

    func saveConnection(_ c: StoredConnection, accounts: [SourceAccount]) throws {
        try db.transaction {
            try db.run("""
                INSERT INTO connection(id, institution, country, environment, status, cursor, last_sync, history_status)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET institution = excluded.institution, status = excluded.status
                """, [c.id.sql, c.institution.sql, c.country.sql, c.environment.sql, c.status.sql, c.cursor.sql,
                      c.lastSync.map { iso.string(from: $0) }.sql, c.historyStatus.sql])
            for a in accounts {
                try db.run("""
                    INSERT INTO source_account(id, connection_id, name, mask, type, subtype, currency)
                    VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, mask = excluded.mask
                    """, [a.id.sql, c.id.sql, a.name.sql, a.mask.sql, a.type.sql, a.subtype.sql, a.currency.sql])
            }
        }
    }

    func setStatus(_ status: String, connection id: String) throws {
        try db.run("UPDATE connection SET status = ? WHERE id = ?", [status.sql, id.sql])
    }

    func setHistoryStatus(_ status: String?, connection id: String) throws {
        try db.run("UPDATE connection SET history_status = ? WHERE id = ?", [status.sql, id.sql])
    }

    /// After disconnect the Item token is gone, so the cursor is closed. Local history stays.
    func closeConnection(_ id: String) throws {
        try db.run("UPDATE connection SET status = 'disconnected', cursor = NULL WHERE id = ?", [id.sql])
    }

    func accounts(connection id: String) throws -> [SourceAccount] {
        try db.query("SELECT * FROM source_account WHERE connection_id = ? ORDER BY type, name", [id.sql]).map(account)
    }

    private func account(_ r: Row) -> SourceAccount {
        SourceAccount(id: r["id"]!.string!, connectionID: r["connection_id"]!.string!, name: r["name"]!.string!,
                      mask: r["mask"]?.string, type: r["type"]!.string!, subtype: r["subtype"]?.string,
                      currency: r["currency"]?.string, cardID: r["card_id"]?.string, ignored: r["ignored"]?.bool ?? false)
    }

    func setIgnored(_ ignored: Bool, accounts ids: [String]) throws {
        try db.transaction {
            for id in ids { try db.run("UPDATE source_account SET ignored = ? WHERE id = ?", [ignored.sql, id.sql]) }
        }
    }

    /// Restores every hidden account so it can be mapped again.
    func unhideAllAccounts() throws { try db.run("UPDATE source_account SET ignored = 0 WHERE ignored = 1 AND card_id IS NULL") }

    func hiddenAccountCount(environment: String?) throws -> Int {
        try db.query("""
            SELECT COUNT(*) AS n FROM source_account a JOIN connection c ON c.id = a.connection_id
            WHERE a.ignored = 1 AND a.card_id IS NULL AND a.type = 'credit' AND c.status != 'disconnected' AND (? IS NULL OR c.environment = ?)
            """, [environment.sql, environment.sql]).first?["n"]?.int ?? 0
    }

    // MARK: - Cards

    /// Creates cards for confirmed mappings and assigns their source accounts. Resets the cursor when the
    /// mapping widened, so history for newly mapped accounts is pulled again (duplicates are ignored by source ID).
    func confirmMapping(connection id: String, _ mapping: [(account: SourceAccount, productID: String, nickname: String)]) throws {
        try db.transaction {
            for m in mapping {
                let cardID = UUID().uuidString
                try db.run("""
                    INSERT INTO card(id, nickname, product_id, mask, connection_id, created_at) VALUES(?,?,?,?,?,?)
                    """, [cardID.sql, m.nickname.sql, m.productID.sql, m.account.mask.sql, id.sql, iso.string(from: Date()).sql])
                try db.run("UPDATE source_account SET card_id = ?, ignored = 0 WHERE id = ?", [cardID.sql, m.account.id.sql])
            }
            if !mapping.isEmpty { try db.run("UPDATE connection SET cursor = NULL WHERE id = ?", [id.sql]) }
        }
    }

    // MARK: - Open-date confirmation, renewal date, and welcome offers

    func setOpenDate(cardID: String, date: Date?, status: OpenDateStatus) throws {
        try db.run("UPDATE card SET opened_on = COALESCE(?, opened_on), opened_status = ? WHERE id = ?",
                   [date.map { Day.key($0) }.sql, status.rawValue.sql, cardID.sql])
    }

    /// Switches the card to another catalog product (the owner picked the wrong card type).
    func setProduct(cardID: String, productID: String, nickname: String) throws {
        try db.run("UPDATE card SET product_id = ?, nickname = ? WHERE id = ?", [productID.sql, nickname.sql, cardID.sql])
    }

    func setRenewal(cardID: String, date: Date?, precision: RenewalDate.Precision = .day, source: RenewalDate.Source = .owner) throws {
        try db.run("UPDATE card SET renewal_date = ?, renewal_precision = ?, renewal_source = ? WHERE id = ?",
                   [date.map { Day.key($0) }.sql, (date == nil ? nil : precision.rawValue).sql,
                    (date == nil ? nil : source.rawValue).sql, cardID.sql])
    }

    func welcomeOffers() throws -> [WelcomeOffer] {
        try db.query("SELECT * FROM welcome_offer ORDER BY start").compactMap { r in
            guard let kind = WelcomeOffer.Kind(rawValue: r["kind"]?.string ?? ""),
                  let start = Day.parse(r["start"]?.string),
                  let currency = CurrencyCode(rawValue: r["currency"]?.string ?? "") else { return nil }
            func money(_ k: String) -> Money? { r[k]?.int.map { Money($0, currency) } }
            func double(_ k: String) -> Double? { if case .real(let d) = r[k] { d } else { r[k]?.int.map(Double.init) } }
            let cats = (r["categories"]?.string ?? "").split(separator: ",").compactMap { RewardCategory(rawValue: String($0)) }
            return WelcomeOffer(id: r["id"]!.string!, cardID: r["card_id"]!.string!, kind: kind, currency: currency, start: start,
                                months: r["months"]?.int ?? 3, minSpend: money("min_spend_minor"), points: double("points"),
                                cash: money("cash_minor"), extraMultiplier: double("extra_multiplier"), categories: Set(cats),
                                spendCap: money("spend_cap_minor"), notes: r["notes"]?.string ?? "", markedEarned: r["earned"]?.bool ?? false)
        }
    }

    func saveWelcomeOffer(_ o: WelcomeOffer, currency: CurrencyCode) throws {
        let pointsValue: SQLValue = o.points.map { .real($0) } ?? .null
        let multValue: SQLValue = o.extraMultiplier.map { .real($0) } ?? .null
        try db.run("""
            INSERT OR REPLACE INTO welcome_offer(id, card_id, kind, start, months, currency, min_spend_minor, points, cash_minor,
              extra_multiplier, categories, spend_cap_minor, notes, earned) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [o.id.sql, o.cardID.sql, o.kind.rawValue.sql, Day.key(o.start).sql, o.months.sql, currency.rawValue.sql,
                  o.minSpend.map { .int(Int64($0.minor)) } ?? .null, pointsValue, o.cash.map { .int(Int64($0.minor)) } ?? .null,
                  multValue, o.categories.map(\.rawValue).sorted().joined(separator: ",").sql,
                  o.spendCap.map { .int(Int64($0.minor)) } ?? .null, o.notes.sql, o.markedEarned.sql])
    }

    func deleteWelcomeOffer(_ id: String) throws {
        try db.run("DELETE FROM welcome_offer WHERE id = ?", [id.sql])
    }

    /// A card without a bank feed (design §3: "Add card manually").
    func createManualCard(nickname: String, productID: String, mask: String?, openedOn: Date, renewal: Date?) throws {
        let sql = "INSERT INTO card(id, nickname, product_id, mask, opened_on, renewal_date, renewal_precision, renewal_source, created_at, opened_status) VALUES(?,?,?,?,?,?,?,?,?,'confirmed')"
        try db.run(sql, [UUID().uuidString.sql, nickname.sql, productID.sql, mask.sql, Day.key(openedOn).sql,
                         renewal.map { Day.key($0) }.sql, (renewal == nil ? nil : "day").sql,
                         (renewal == nil ? nil : RenewalDate.Source.owner.rawValue).sql, iso.string(from: Date()).sql])
    }

    func loadCards() throws -> [Card] {
        let conns = Dictionary(uniqueKeysWithValues: try connections().map { ($0.id, $0) })
        let starts = Dictionary(uniqueKeysWithValues: try db.query("SELECT card_id, MIN(posted) AS first FROM txn GROUP BY card_id").compactMap { r -> (String, String)? in
            guard let c = r["card_id"]?.string, let f = r["first"]?.string else { return nil }
            return (c, f)
        })
        let importedSources = Dictionary(uniqueKeysWithValues: try db.query("""
            SELECT card_id,
                   MAX(CASE WHEN provenance = 'PDF statement' THEN 1 ELSE 0 END) AS has_pdf,
                   MAX(CASE WHEN provenance = 'CSV import' THEN 1 ELSE 0 END) AS has_csv
            FROM txn GROUP BY card_id
            """).compactMap { r -> (String, ConnectionState)? in
            guard let c = r["card_id"]?.string else { return nil }
            if r["has_pdf"]?.bool == true { return (c, .pdf) }
            if r["has_csv"]?.bool == true { return (c, .csv) }
            return nil
        })
        return try db.query("SELECT * FROM card ORDER BY created_at").map { r in
            let id = r["id"]!.string!
            let conn = r["connection_id"]?.string.flatMap { conns[$0] }
            let state: ConnectionState = switch conn?.status {
            case "active": .plaid(institution: conn!.institution)
            case "login_required": .reauthRequired(institution: conn!.institution)
            case "disconnect_pending": .disconnectPending(institution: conn!.institution)
            case "disconnected": .disconnected(institution: conn!.institution)
            default: importedSources[id] ?? .manual
            }
            let created = r["created_at"]?.string.flatMap { iso.date(from: $0) } ?? Date()
            let renewal: RenewalDate? = Day.parse(r["renewal_date"]?.string).map {
                RenewalDate(date: $0, precision: RenewalDate.Precision(rawValue: r["renewal_precision"]?.string ?? "") ?? .day,
                            source: RenewalDate.Source(rawValue: r["renewal_source"]?.string ?? "") ?? .owner)
            }
            let historyStart = Day.parse(starts[id]) ?? Day.startOfMonth(created)
            let storedOpened = Day.parse(r["opened_on"]?.string)
            // Plaid doesn't report an account-open date. Until the owner sets one, use the start of covered history:
            // the account was open by then, so it's an "on or before" estimate.
            return Card(id: id, nickname: r["nickname"]!.string!, productID: r["product_id"]!.string!, mask: r["mask"]?.string,
                        openedOn: storedOpened ?? historyStart, renewal: renewal,
                        connection: state, lastSync: conn?.lastSync,
                        historyStart: historyStart,
                        isAuthorizedUser: r["is_au"]?.bool ?? false, connectionID: conn?.id,
                        openedIsEstimate: storedOpened == nil,
                        openDateStatus: OpenDateStatus(rawValue: r["opened_status"]?.string ?? "")
                            ?? (storedOpened == nil ? .estimated : .confirmed))
        }
    }

    /// Deletes a card's local history: transactions, their matches and overrides. Unmaps its source account.
    func deleteCard(_ cardID: String) throws {
        try db.transaction {
            for account in try db.query("SELECT id, connection_id FROM source_account WHERE card_id = ?", [cardID.sql]) {
                guard let accountID = account["id"]?.string, let connectionID = account["connection_id"]?.string,
                      let report = billReport(connectionID: connectionID) else { continue }
                let bills = report.response.bills.filter { $0.accountId != accountID }
                let updated = BillReport(serviceURL: report.serviceURL, accountUserID: report.accountUserID, fetchedAt: report.fetchedAt,
                                         response: CreditCardBills(status: report.response.status, bills: bills))
                try saveBillReport(updated, connectionID: connectionID)
            }
            try db.run("DELETE FROM decision WHERE credit_id IN (SELECT id FROM txn WHERE card_id = ?)", [cardID.sql])
            try db.run("DELETE FROM category_override WHERE txn_id IN (SELECT id FROM txn WHERE card_id = ?)", [cardID.sql])
            try db.run("DELETE FROM txn WHERE card_id = ?", [cardID.sql])
            try db.run("DELETE FROM welcome_offer WHERE card_id = ?", [cardID.sql])
            try db.run("DELETE FROM award_certificate WHERE card_id = ?", [cardID.sql])
            try db.run("DELETE FROM benefit_usage WHERE period_id LIKE ?", ["%|\(cardID)|%".sql])
            try db.run("DELETE FROM setting WHERE key LIKE ?", ["membership.\(cardID).%".sql])
            // The account stays linked but hidden, so a deleted card doesn't reappear as "to map".
            try db.run("UPDATE source_account SET card_id = NULL, ignored = 1 WHERE card_id = ?", [cardID.sql])
            try db.run("DELETE FROM card WHERE id = ?", [cardID.sql])
        }
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - In-app credit usage, certificates, memberships

    func usageLogs() throws -> [UsageLog] {
        try db.query("SELECT * FROM benefit_usage ORDER BY used_on DESC").compactMap { r in
            guard let c = CurrencyCode(rawValue: r["currency"]?.string ?? ""), let used = Day.parse(r["used_on"]?.string) else { return nil }
            return UsageLog(id: r["id"]!.string!, periodID: r["period_id"]!.string!, amount: Money(r["amount_minor"]?.int ?? 0, c),
                            usedOn: used, note: r["note"]?.string ?? "")
        }
    }

    func addUsage(_ u: UsageLog) throws {
        try db.run("INSERT INTO benefit_usage(id, period_id, amount_minor, currency, used_on, note, logged_at) VALUES(?,?,?,?,?,?,?)",
                   [u.id.sql, u.periodID.sql, u.amount.minor.sql, u.amount.currency.rawValue.sql, Day.key(u.usedOn).sql,
                    u.note.sql, iso.string(from: Date()).sql])
    }

    func deleteUsage(_ id: String) throws { try db.run("DELETE FROM benefit_usage WHERE id = ?", [id.sql]) }

    func certificates() throws -> [AwardCertificate] {
        try db.query("SELECT * FROM award_certificate ORDER BY expires_on").compactMap { r in
            guard let issued = Day.parse(r["issued_on"]?.string), let expires = Day.parse(r["expires_on"]?.string) else { return nil }
            return AwardCertificate(id: r["id"]!.string!, cardID: r["card_id"]!.string!, ruleID: r["rule_id"]!.string!,
                                    issuedOn: issued, expiresOn: expires, redeemedOn: Day.parse(r["redeemed_on"]?.string),
                                    note: r["note"]?.string ?? "")
        }
    }

    func saveCertificate(_ c: AwardCertificate) throws {
        try db.run("INSERT OR REPLACE INTO award_certificate(id, card_id, rule_id, issued_on, expires_on, redeemed_on, note) VALUES(?,?,?,?,?,?,?)",
                   [c.id.sql, c.cardID.sql, c.ruleID.sql, Day.key(c.issuedOn).sql, Day.key(c.expiresOn).sql,
                    c.redeemedOn.map { Day.key($0) }.sql, c.note.sql])
    }

    func deleteCertificate(_ id: String) throws { try db.run("DELETE FROM award_certificate WHERE id = ?", [id.sql]) }

    // MARK: - Transactions

    /// Count of rows whose currency is missing or unofficial; kept for review instead of being guessed.
    func unknownCurrencyCount() throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM txn WHERE currency IS NULL OR currency NOT IN ('USD','CAD')").first?["n"]?.int ?? 0
    }

    func loadTransactions() throws -> [Transaction] {
        try db.query("SELECT * FROM txn ORDER BY posted DESC").compactMap { r in
            guard let currency = r["currency"]?.string.flatMap(CurrencyCode.init(rawValue:)),
                  let posted = Day.parse(r["posted"]?.string) else { return nil }
            let amount = Money(r["amount_minor"]!.int!, currency)
            let merchant = r["merchant"]!.string!
            let original = r["original_description"]!.string!
            let storedKind = TransactionKind(rawValue: r["kind"]!.string!) ?? .purchase
            // Older app builds stored positive hotel credits as purchases or fees.
            let mayBeReversal = amount.minor > 0 && (storedKind == .purchase || storedKind == .fee)
            let description = mayBeReversal ? PlaidMapping.hotelCreditDescription(original, alternate: merchant) : original
            let kind: TransactionKind = mayBeReversal && PlaidMapping.isAmexHotelCredit(description) ? .issuerCreditReversal : storedKind
            return Transaction(
                id: r["id"]!.string!, cardID: r["card_id"]!.string!,
                amount: amount, posted: posted, authorized: Day.parse(r["authorized"]?.string),
                merchant: merchant, originalDescription: description,
                category: RewardCategory(rawValue: r["category"]!.string!) ?? .other,
                kind: kind,
                pending: r["pending"]!.bool, provenance: Provenance(rawValue: r["provenance"]!.string!) ?? .plaid,
                mcc: r["mcc"]?.string)
        }
    }

    /// Applies a staged batch and the new cursor in one database transaction. A failure leaves the
    /// previously committed cursor and ledger untouched.
    @discardableResult
    func apply(_ batch: SyncBatch, connection id: String, cursor: String) throws -> SyncApplyResult {
        try db.transaction {
            var result = SyncApplyResult()
            let accountToCard = Dictionary(uniqueKeysWithValues: try db.query(
                "SELECT id, card_id FROM source_account WHERE connection_id = ? AND card_id IS NOT NULL", [id.sql]
            ).map { ($0["id"]!.string!, $0["card_id"]!.string!) })

            for page in batch.pages {
                for t in page.added + page.modified {
                    guard let cardID = accountToCard[t.accountId] else { result.skippedUnmapped += 1; continue }
                    let sourceID = "plaid:\(t.id)"
                    let existing = try db.query("SELECT id FROM txn WHERE source_id = ?", [sourceID.sql]).first?["id"]?.string
                    // Pending → posted keeps the stable local ID, so owner overrides and matches survive.
                    let fromPending = existing == nil
                        ? try t.pendingTransactionId.flatMap { try db.query("SELECT id FROM txn WHERE source_id = ?", ["plaid:\($0)".sql]).first?["id"]?.string }
                        : nil
                    let localID = existing ?? fromPending ?? UUID().uuidString
                    // Unofficial currencies are stored as NULL so they are surfaced in unknownCurrencyCount() instead of guessed.
                    let officialCurrency: String? = t.currencyIsOfficial ? t.currency : nil
                    let args: [SQLValue] = [
                        cardID.sql, sourceID.sql, t.amountMinor.sql, officialCurrency.sql, String(t.date.prefix(10)).sql,
                        t.authorizedDate.map { String($0.prefix(10)) }.sql, PlaidMapping.displayMerchant(t).sql,
                        PlaidMapping.statementDescription(t).sql, PlaidMapping.category(t).rawValue.sql, PlaidMapping.kind(t).rawValue.sql,
                        t.pending.sql, t.merchantCategoryCode.sql, localID.sql,
                    ]
                    if existing != nil || fromPending != nil {
                        try db.run("""
                            UPDATE txn SET card_id=?, source_id=?, amount_minor=?, currency=?, posted=?, authorized=?, merchant=?,
                              original_description=?, category=?, kind=?, pending=?, mcc=? WHERE id = ?
                            """, args)
                        result.updated += 1
                    } else {
                        try db.run("""
                            INSERT INTO txn(card_id, source_id, amount_minor, currency, posted, authorized, merchant,
                              original_description, category, kind, pending, mcc, id, provenance)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'Plaid')
                            """, args)
                        result.inserted += 1
                    }
                }

                for removedID in page.removed {
                    let rows = try db.query("SELECT id FROM txn WHERE source_id = ?", ["plaid:\(removedID)".sql])
                    for r in rows {
                        let local = r["id"]!.string!
                        try db.run("DELETE FROM decision WHERE credit_id = ?", [local.sql])
                        try db.run("DELETE FROM category_override WHERE txn_id = ?", [local.sql])
                        try db.run("DELETE FROM txn WHERE id = ?", [local.sql])
                        result.removed += 1
                    }
                }
            }

            try db.run("UPDATE connection SET cursor = ?, last_sync = ?, history_status = COALESCE(?, history_status) WHERE id = ?",
                       [cursor.sql, iso.string(from: Date()).sql, batch.historyStatus.sql, id.sql])
            return result
        }
    }

    // MARK: - Owner decisions (kept across syncs)

    func decisions() throws -> [String: ReviewDecision] {
        var out: [String: ReviewDecision] = [:]
        for r in try db.query("SELECT * FROM decision") {
            let id = r["credit_id"]!.string!
            out[id] = r["kind"]?.string == "assign" ? .assign(periodID: r["period_id"]?.string ?? "") : .keepUnmatched
        }
        return out
    }

    func saveDecision(_ creditID: String, _ d: ReviewDecision?) throws {
        guard let d else { try db.run("DELETE FROM decision WHERE credit_id = ?", [creditID.sql]); return }
        let (kind, period): (String, String?) = switch d {
        case .assign(let p): ("assign", p)
        case .keepUnmatched: ("unmatched", nil)
        }
        try db.run("INSERT OR REPLACE INTO decision(credit_id, kind, period_id, decided_at) VALUES(?,?,?,?)",
                   [creditID.sql, kind.sql, period.sql, iso.string(from: Date()).sql])
    }

    func categoryOverrides() throws -> [String: RewardCategory] {
        var out: [String: RewardCategory] = [:]
        for r in try db.query("SELECT * FROM category_override") {
            if let c = RewardCategory(rawValue: r["category"]!.string!) { out[r["txn_id"]!.string!] = c }
        }
        return out
    }

    func saveCategoryOverride(_ txnID: String, _ c: RewardCategory) throws {
        try db.run("INSERT OR REPLACE INTO category_override(txn_id, category, edited_at) VALUES(?,?,?)",
                   [txnID.sql, c.rawValue.sql, iso.string(from: Date()).sql])
    }
}
