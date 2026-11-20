import Foundation

/// A locally stored credit card payment due date captured from an imported PDF statement, CSV export,
/// or manual edit on this iPhone. Stored encrypted inside the SQLCipher `setting` table (design §6).
struct StatementBill: Codable, Hashable, Identifiable {
    enum Source: String, Codable, Hashable {
        case pdf = "PDF statement"
        case csv = "CSV import"
        case manual = "Manual"
    }

    let cardID: String
    /// Date-only key (`YYYY-MM-DD`) in `Day.calendar` so persistence is immune to time-zone shifts.
    let dueDateKey: String
    let statementDateKey: String?
    let source: Source
    var paidOnKey: String?
    var updatedAt: Date

    var id: String { cardID }

    var dueDate: Date? {
        guard dueDateKey.utf8.count == 10, let d = Day.parse(dueDateKey), Day.key(d) == dueDateKey else { return nil }
        return d
    }

    var statementDate: Date? {
        statementDateKey.flatMap { key in
            guard key.utf8.count == 10, let d = Day.parse(key), Day.key(d) == key else { return nil }
            return d
        }
    }

    var paidOn: Date? {
        paidOnKey.flatMap { key in
            guard key.utf8.count == 10, let d = Day.parse(key), Day.key(d) == key else { return nil }
            return d
        }
    }

    var isPaid: Bool { paidOn != nil }

    init(
        cardID: String,
        dueDate: Date,
        statementDate: Date? = nil,
        source: Source,
        paidOn: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.cardID = cardID
        self.dueDateKey = Day.key(dueDate)
        self.statementDateKey = statementDate.map { Day.key($0) }
        self.source = source
        self.paidOnKey = paidOn.map { Day.key($0) }
        self.updatedAt = updatedAt
    }

    /// Merges a newly imported statement due date with an existing stored bill for the same card.
    ///
    /// - Importing an older historical statement never overwrites a newer due date unless `forceReplace` is set.
    /// - Re-importing the same statement preserves `paidOn` so already-paid cycles stay silenced.
    func merged(over existing: StatementBill?, forceReplace: Bool = false) -> StatementBill? {
        guard let newDue = dueDate else { return nil }
        guard let existing, let existingDue = existing.dueDate else { return self }
        if !forceReplace && newDue < existingDue { return nil }
        if !forceReplace && newDue == existingDue {
            var copy = self
            copy.paidOnKey = existing.paidOnKey
            return copy
        }
        return self
    }
}

/// Unified upcoming card payment shown in Overview and Card Detail, combining Plaid Liabilities
/// due dates and on-device statement-imported due dates without duplicating cards.
struct UpcomingCardBill: Identifiable, Hashable {
    enum Origin: Hashable {
        case plaid
        case statement(StatementBill.Source)

        var label: String {
            switch self {
            case .plaid: "Plaid"
            case .statement(let source): source.rawValue
            }
        }
    }

    let cardID: String
    let dueDate: Date
    let origin: Origin
    let statementBill: StatementBill?

    var id: String { cardID }

    func daysUntilDue(from today: Date) -> Int {
        Day.days(from: today, to: dueDate)
    }

    static func merge(
        plaid: [BillPayment],
        statement: [StatementBill],
        validCardIDs: Set<String>,
        today: Date
    ) -> [UpcomingCardBill] {
        var byCard: [String: UpcomingCardBill] = [:]

        for bill in plaid where validCardIDs.contains(bill.cardID) && bill.dueDate >= today {
            if let existing = byCard[bill.cardID], existing.dueDate <= bill.dueDate { continue }
            byCard[bill.cardID] = UpcomingCardBill(cardID: bill.cardID, dueDate: bill.dueDate, origin: .plaid, statementBill: nil)
        }

        for bill in statement {
            guard validCardIDs.contains(bill.cardID), !bill.isPaid, let due = bill.dueDate, due >= today else { continue }
            if let existing = byCard[bill.cardID] {
                // Keep whichever upcoming due date is sooner; when Plaid and the statement agree on the same due date,
                // keep Plaid as the primary source so notifications are not duplicated.
                if due < existing.dueDate {
                    byCard[bill.cardID] = UpcomingCardBill(cardID: bill.cardID, dueDate: due, origin: .statement(bill.source), statementBill: bill)
                }
            } else {
                byCard[bill.cardID] = UpcomingCardBill(cardID: bill.cardID, dueDate: due, origin: .statement(bill.source), statementBill: bill)
            }
        }

        return byCard.values.sorted { ($0.dueDate, $0.cardID) < ($1.dueDate, $1.cardID) }
    }
}

/// Local notification schedule entries for statement-imported payment due dates.
/// Uses the `"statement-bill."` identifier prefix so it coexists cleanly with Plaid `"bill-payment."` alerts.
struct StatementBillAlertTime: Identifiable, Equatable {
    static let prefix = "statement-bill."

    let id: String
    let cardID: String
    let components: DateComponents
    let fireDate: Date
    let dueThatDay: Bool

    static func upcoming(
        for bills: [StatementBill],
        excludingPlaidBills plaidBills: [BillPayment] = [],
        after now: Date,
        offsets: [Int] = [3, 0],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [Self] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let plaidCovered = Set(plaidBills.map { "\($0.cardID)|\(Day.key($0.dueDate))" })
        let sortedOffsets = Array(Set(offsets.filter { $0 >= 0 })).sorted(by: >)

        return bills.flatMap { bill -> [Self] in
            guard !bill.isPaid, let dueDate = bill.dueDate else { return [] }
            if plaidCovered.contains("\(bill.cardID)|\(bill.dueDateKey)") { return [] }
            return sortedOffsets.compactMap { offset -> Self? in
                let day = Day.ymd(Day.add(-offset, to: dueDate))
                let components = DateComponents(calendar: calendar, year: day.y, month: day.m, day: day.d, hour: 9, minute: 0)
                guard let fireDate = calendar.date(from: components), fireDate > now else { return nil }
                return Self(
                    id: "\(prefix)\(bill.cardID).\(bill.dueDateKey).\(offset)",
                    cardID: bill.cardID,
                    components: components,
                    fireDate: fireDate,
                    dueThatDay: offset == 0
                )
            }
        }.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
    }
}
