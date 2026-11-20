import Foundation

/// Local notification schedule entries for upcoming credit-card benefit deadlines.
/// Uses the `"benefit-deadline."` identifier prefix so it coexists cleanly with
/// Plaid `"bill-payment."` and statement `"statement-bill."` alerts.
struct BenefitAlertTime: Identifiable, Equatable, Sendable {
    static let prefix = "benefit-deadline."
    static let supportedOffsets = [14, 7, 2]
    /// Reminders whose underlying data will be more than 24 hours old at fire time use stale-data wording (CL-21).
    static let staleDataInterval: TimeInterval = 24 * 60 * 60

    static let freshBody = "A card benefit deadline is approaching. Open Card Ledger to review."
    static let staleBody = "A card benefit deadline is approaching. The credit may already be used. Open Card Ledger to refresh."

    let id: String
    let deadlineDay: Date
    let offsetDays: Int
    let components: DateComponents
    let fireDate: Date
    let isStaleData: Bool

    var body: String { isStaleData ? Self.staleBody : Self.freshBody }

    /// Computes upcoming 9:00 AM local-time benefit deadline notifications for open periods.
    /// Periods sharing the same deadline day and offset coalesce into one generic lock-screen alert
    /// to respect iOS's 64-notification ceiling without repeating identical messages.
    static func upcoming(
        for periods: [BenefitPeriod],
        offsets: Set<Int>,
        after now: Date,
        today: Date? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [Self] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let currentDay: Date
        if let today {
            currentDay = today
        } else {
            let local = calendar.dateComponents([.year, .month, .day], from: now)
            currentDay = Day.make(local.year!, local.month!, local.day!)
        }

        let validOffsets = Array(Set(offsets.filter { $0 >= 0 })).sorted(by: >)
        guard !validOffsets.isEmpty else { return [] }

        let openPeriods = periods.filter { $0.isCurrent(today: currentDay) && $0.remaining.minor > 0 }
        guard !openPeriods.isEmpty else { return [] }

        let groupedByDeadline = Dictionary(grouping: openPeriods, by: \.lastDay)

        var alerts: [Self] = []
        for (deadlineDay, deadlinePeriods) in groupedByDeadline {
            let deadlineKey = Day.key(deadlineDay)
            for offset in validOffsets {
                let reminderDay = Day.ymd(Day.add(-offset, to: deadlineDay))
                let components = DateComponents(
                    calendar: calendar,
                    year: reminderDay.y,
                    month: reminderDay.m,
                    day: reminderDay.d,
                    hour: 9,
                    minute: 0
                )
                guard let fireDate = calendar.date(from: components), fireDate > now else { continue }
                let stale = deadlinePeriods.contains { isStale(for: $0, fireDate: fireDate, now: now) }
                alerts.append(Self(
                    id: "\(prefix)\(deadlineKey).\(offset)",
                    deadlineDay: deadlineDay,
                    offsetDays: offset,
                    components: components,
                    fireDate: fireDate,
                    isStaleData: stale
                ))
            }
        }

        return alerts.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
    }

    static func isStale(for period: BenefitPeriod, fireDate: Date, now: Date) -> Bool {
        if let lastSync = period.card.lastSync {
            return fireDate.timeIntervalSince(lastSync) > staleDataInterval
        }
        // A linked card that has never completed a sync has no fresh transaction data.
        if hasBankFeed(period.card) {
            return true
        }
        // Manual and statement-imported cards have no sync feed; warn if the reminder fires more than
        // a day after the app last evaluated the schedule.
        return fireDate.timeIntervalSince(now) > staleDataInterval
    }

    private static func hasBankFeed(_ card: Card) -> Bool {
        if card.connectionID != nil { return true }
        switch card.connection {
        case .plaid, .reauthRequired, .disconnectPending: return true
        default: return false
        }
    }
}
