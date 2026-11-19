import Foundation

struct CreditCardBills: Codable {
    enum Status: String, Codable {
        case available, unavailable, disabled
        case consentRequired = "consent_required"
    }

    struct Bill: Codable {
        let accountId: String
        let dueDate: String

        var day: Date? {
            guard dueDate.utf8.count == 10, let day = Day.parse(dueDate), Day.key(day) == dueDate else { return nil }
            return day
        }
    }

    let status: Status
    let bills: [Bill]
}

struct BillPayment: Identifiable {
    let cardID: String
    let dueDate: Date
    var id: String { cardID }
}

struct BillAlertTime: Identifiable {
    static let prefix = "bill-payment."

    let id: String
    let components: DateComponents
    let fireDate: Date
    let dueThatDay: Bool

    static func upcoming(for bills: [BillPayment], after now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> [Self] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return bills.flatMap { bill in
            [3, 0].compactMap { offset -> Self? in
                let day = Day.ymd(Day.add(-offset, to: bill.dueDate))
                let components = DateComponents(calendar: calendar, year: day.y, month: day.m, day: day.d, hour: 9, minute: 0)
                guard let date = calendar.date(from: components), date > now else { return nil }
                return Self(id: "\(prefix)\(bill.cardID).\(offset)", components: components, fireDate: date, dueThatDay: offset == 0)
            }
        }.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
    }
}
