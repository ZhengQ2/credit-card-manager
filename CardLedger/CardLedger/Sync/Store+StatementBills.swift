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
            statement: statementBills.values.filter { !isSettledByPayment($0) },
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
        // Ask for notification permission only when reminders can actually be delivered, and never after the
        // user turned bill alerts off.
        if statementRemindersAllowed, !merged.isPaid, let due = merged.dueDate, due >= today,
           !(await statementBillNotifications.hasAccess()) {
            await statementBillNotifications.requestAccess()
        }
        updateStatementBillNotifications()
        return true
    }

    /// True when a card payment posted after the statement (or within the 25 days before the due date when the
    /// statement date is unknown) and by the due date, so reminders for that bill stop without a manual "Mark paid".
    func isSettledByPayment(_ bill: StatementBill) -> Bool {
        guard !bill.isPaid, let due = bill.dueDate else { return false }
        let from = bill.statementDate ?? Day.add(-25, to: due)
        return effectiveTransactions.contains {
            $0.cardID == bill.cardID && $0.kind == .payment && $0.amount.minor < 0 && !$0.pending
                && $0.posted > from && $0.posted <= due
        }
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

    /// Statement reminders are opted into per card, so they work without signing in. They're silenced when the
    /// signed-in user has explicitly turned off Bill payment alerts.
    var statementRemindersAllowed: Bool {
        guard let session = serviceSession, let repo else { return true }
        return repo.setting("bill_alert_choice.\(session.userID)") != "skipped"
    }

    func updateStatementBillNotifications() {
        let validIDs = mode == .live && statementRemindersAllowed ? Set(cards.map(\.id)) : []
        let active = statementBills.values
            .filter { validIDs.contains($0.cardID) && !isSettledByPayment($0) }
            .sorted { $0.cardID < $1.cardID }
        let plaid = upcomingCardBills
        let signature = active.map { "\($0.cardID)|\($0.dueDateKey)|\($0.paidOnKey ?? "")" }
            + plaid.map { "p|\($0.cardID)|\(Day.key($0.dueDate))" }
        // Reload runs often; only touch the notification center when the inputs changed.
        guard signature != lastStatementAlertSignature else { return }
        lastStatementAlertSignature = signature
        statementBillNotifications.update(active, excludingPlaidBills: plaid)
    }
}
