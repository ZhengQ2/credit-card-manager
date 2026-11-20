import Foundation

extension LedgerRepository {
    private static let statementBillPrefix = "statement_bill."

    func statementBills() throws -> [String: StatementBill] {
        var out: [String: StatementBill] = [:]
        for (key, raw) in try settings(prefix: Self.statementBillPrefix) where key.hasPrefix(Self.statementBillPrefix) {
            guard let bill = try? JSONDecoder().decode(StatementBill.self, from: Data(raw.utf8)) else { continue }
            out[bill.cardID] = bill
        }
        return out
    }

    func saveStatementBill(_ bill: StatementBill?, cardID: String) throws {
        let value = try bill.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try setSetting("\(Self.statementBillPrefix)\(cardID)", value)
    }
}

@MainActor
extension Store {
    /// Unified upcoming card payment list combining Plaid Liabilities due dates and local PDF/CSV statement due dates.
    var allUpcomingCardBills: [UpcomingCardBill] {
        guard mode == .live else { return [] }
        return UpcomingCardBill.merge(
            plaid: upcomingCardBills,
            statement: Array(statementBills.values),
            validCardIDs: Set(cards.map(\.id)),
            today: today
        )
    }

    func statementBill(for cardID: String) -> StatementBill? {
        guard mode == .live else { return nil }
        return statementBills[cardID]
    }

    func upcomingBill(for cardID: String) -> UpcomingCardBill? {
        allUpcomingCardBills.first { $0.cardID == cardID }
    }

    /// Saves a payment due date from a PDF statement, CSV import, or manual edit and schedules local reminders.
    /// Returns `true` if a reminder was saved or updated, or `false` if an existing newer due date was kept.
    @discardableResult
    func saveStatementBill(
        cardID: String,
        dueDate: Date,
        statementDate: Date? = nil,
        source: StatementBill.Source,
        forceReplace: Bool = false
    ) async -> Bool {
        guard mode == .live, let repo else { return false }
        let candidate = StatementBill(cardID: cardID, dueDate: dueDate, statementDate: statementDate, source: source)
        guard let merged = candidate.merged(over: statementBills[cardID], forceReplace: forceReplace) else {
            return false
        }
        do {
            try repo.saveStatementBill(merged, cardID: cardID)
        } catch {
            syncMessage = error.localizedDescription
            return false
        }
        statementBills[cardID] = merged
        if !merged.isPaid, let due = merged.dueDate, due >= today {
            await statementBillNotifications.requestAccess()
        }
        updateStatementBillNotifications()
        return true
    }

    func markStatementBillPaid(_ paid: Bool, for cardID: String) {
        guard mode == .live, let repo, var bill = statementBills[cardID] else { return }
        bill.paidOnKey = paid ? Day.key(today) : nil
        bill.updatedAt = Date()
        do {
            try repo.saveStatementBill(bill, cardID: cardID)
        } catch {
            syncMessage = error.localizedDescription
            return
        }
        statementBills[cardID] = bill
        updateStatementBillNotifications()
    }

    func removeStatementBill(for cardID: String) {
        guard mode == .live, let repo else { return }
        do {
            try repo.saveStatementBill(nil, cardID: cardID)
        } catch {
            syncMessage = error.localizedDescription
            return
        }
        statementBills.removeValue(forKey: cardID)
        updateStatementBillNotifications()
    }

    func updateStatementBillNotifications() {
        let validIDs = mode == .live ? Set(cards.map(\.id)) : []
        let active = statementBills.values.filter { validIDs.contains($0.cardID) }
        statementBillNotifications.update(Array(active), excludingPlaidBills: upcomingCardBills)
    }
}
