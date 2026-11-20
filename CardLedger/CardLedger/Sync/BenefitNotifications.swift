import Observation
import UserNotifications

/// Minimal abstraction over `UNUserNotificationCenter` so benefit reminder scheduling
/// and cancellation can be verified deterministically in unit tests.
@MainActor
protocol NotificationCenterClient: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func deliveredNotificationIdentifiers() async -> [String]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
final class SystemNotificationCenter: NotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Schedules local iOS 9:00 AM reminders for open benefit deadlines using the owner's chosen offsets.
/// Manages only `benefit-deadline.*` identifiers so bill-payment alerts stay independent.
@Observable
@MainActor
final class BenefitNotifications {
    private(set) var message: String?
    private(set) var needsAuthorizationPrompt = false
    @ObservationIgnored private let center: NotificationCenterClient
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init(center: NotificationCenterClient? = nil) {
        self.center = center ?? SystemNotificationCenter()
    }

    func hasAccess() async -> Bool {
        Self.canSchedule(await center.authorizationStatus())
    }

    @discardableResult
    func requestAccess() async -> Bool {
        let status = await center.authorizationStatus()
        if Self.canSchedule(status) {
            message = nil
            needsAuthorizationPrompt = false
            return true
        }
        if status == .denied {
            needsAuthorizationPrompt = false
            message = "Allow Card Ledger notifications in iOS Settings to receive benefit reminders."
            return false
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            needsAuthorizationPrompt = false
            message = granted ? nil : "Allow Card Ledger notifications in iOS Settings to receive benefit reminders."
            return granted
        } catch {
            message = "Couldn’t request notification access. Try again."
            return false
        }
    }

    private static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    func update(
        _ periods: [BenefitPeriod],
        offsets: Set<Int>,
        enabled: Bool,
        now: Date = Date(),
        today: Date? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        let previous = updateTask
        updateTask = Task { [weak self] in
            await previous?.value
            await self?.apply(periods, offsets: offsets, enabled: enabled, now: now, today: today, timeZone: timeZone)
        }
    }

    /// Runs the schedule reconciliation directly; invoked serially by `update(...)` and directly in tests.
    func apply(
        _ periods: [BenefitPeriod],
        offsets: Set<Int>,
        enabled: Bool,
        now: Date = Date(),
        today: Date? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) async {
        let status = await center.authorizationStatus()
        let allowed = Self.canSchedule(status)
        let pending = await center.pendingNotificationRequests()
        let existing = pending.filter { $0.identifier.hasPrefix(BenefitAlertTime.prefix) }

        // Respect iOS's 64 pending-notification ceiling without displacing bill-payment alerts.
        let availableSlots = max(0, 64 - (pending.count - existing.count))
        let candidates = enabled
            ? BenefitAlertTime.upcoming(for: periods, offsets: offsets, after: now, today: today, timeZone: timeZone)
            : []
        let upcoming = (allowed ? candidates : []).prefix(availableSlots)
        let keep = Set(upcoming.map(\.id))

        let toCancel = existing.map(\.identifier).filter { !keep.contains($0) }
        if !toCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toCancel)
        }

        if candidates.isEmpty {
            let delivered = await center.deliveredNotificationIdentifiers()
                .filter { $0.hasPrefix(BenefitAlertTime.prefix) }
            if !delivered.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: delivered)
            }
        }

        var failed = false
        for alert in upcoming {
            // Re-schedule if the trigger time OR body changed (e.g. stale-data wording updated after a fresh sync).
            if existing.contains(where: {
                $0.identifier == alert.id
                    && ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents == alert.components
                    && $0.content.body == alert.body
            }) { continue }

            let content = UNMutableNotificationContent()
            content.title = "Card Ledger"
            content.body = alert.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: alert.components, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
            } catch {
                center.removePendingNotificationRequests(withIdentifiers: [alert.id])
                failed = true
            }
        }

        if !candidates.isEmpty && status == .notDetermined {
            needsAuthorizationPrompt = true
            message = "Allow notifications so Card Ledger can deliver benefit reminders."
        } else if !candidates.isEmpty && !allowed {
            needsAuthorizationPrompt = false
            message = "Allow Card Ledger notifications in iOS Settings to receive benefit reminders."
        } else if failed {
            needsAuthorizationPrompt = false
            message = "Some benefit reminders could not be scheduled. Open Settings to retry."
        } else {
            needsAuthorizationPrompt = false
            message = nil
        }
    }
}
