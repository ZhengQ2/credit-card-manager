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
    /// Manual and statement-imported cards have no feed to refresh; use there is recorded by hand.
    static let noFeedBody = "A card benefit deadline is approaching. The credit may already be used. Open Card Ledger to review."

    /// How sure the reminder can be that the credit is still unused when it fires.
    enum Wording: String, Sendable {
        /// Bank data will be less than a day old.
        case fresh
        /// Bank data will be more than a day old, so a sync may show the credit was used.
        case staleFeed
        /// No bank feed, and the app last looked more than a day before the reminder fires.
        case noFeed
    }

    let id: String
    let deadlineDay: Date
    let offsetDays: Int
    let components: DateComponents
    let fireDate: Date
    let wording: Wording

    var isStaleData: Bool { wording != .fresh }

    var body: String {
        switch wording {
        case .fresh: Self.freshBody
        case .staleFeed: Self.staleBody
        case .noFeed: Self.noFeedBody
        }
    }

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
                let wordings = Set(deadlinePeriods.map { wording(for: $0, fireDate: fireDate, now: now) })
                // One alert covers every card with this deadline, so a card that can be refreshed decides the advice.
                let wording: Wording = wordings.contains(.staleFeed) ? .staleFeed : wordings.contains(.noFeed) ? .noFeed : .fresh
                alerts.append(Self(
                    id: "\(prefix)\(deadlineKey).\(offset)",
                    deadlineDay: deadlineDay,
                    offsetDays: offset,
                    components: components,
                    fireDate: fireDate,
                    wording: wording
                ))
            }
        }

        return alerts.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
    }

    static func wording(for period: BenefitPeriod, fireDate: Date, now: Date) -> Wording {
        guard hasBankFeed(period.card) else {
            // Nothing to refresh, but the owner may have used the credit without recording it since the
            // app last scheduled this reminder.
            return fireDate.timeIntervalSince(now) > staleDataInterval ? .noFeed : .fresh
        }
        // A linked card that has never completed a sync has no fresh transaction data.
        guard let lastSync = period.card.lastSync else { return .staleFeed }
        return fireDate.timeIntervalSince(lastSync) > staleDataInterval ? .staleFeed : .fresh
    }

    private static func hasBankFeed(_ card: Card) -> Bool {
        if card.connectionID != nil { return true }
        switch card.connection {
        case .plaid, .reauthRequired, .disconnectPending: return true
        default: return false
        }
    }
}
