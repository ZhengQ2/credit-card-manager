import Observation
import UserNotifications

@Observable
@MainActor
final class BillNotifications {
    private(set) var message: String?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    func hasAccess() async -> Bool { Self.canSchedule(await center.notificationSettings().authorizationStatus) }

    func requestAccess() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        if Self.canSchedule(status) {
            message = nil
            return true
        }
        if status == .denied {
            message = "Allow Card Ledger notifications in iOS Settings to receive alerts."
            return false
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            message = granted ? nil : "Allow Card Ledger notifications in iOS Settings to receive alerts."
            return granted
        } catch {
            message = "Couldn’t request notification access. Try again."
            return false
        }
    }

    private static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    func update(_ bills: [BillPayment], enabled: Bool) {
        let previous = updateTask
        updateTask = Task { [weak self] in
            await previous?.value
            await self?.apply(bills, enabled: enabled)
        }
    }

    private func apply(_ bills: [BillPayment], enabled: Bool) async {
        let settings = await center.notificationSettings()
        let allowed = Self.canSchedule(settings.authorizationStatus)
        let pending = await center.pendingNotificationRequests()
        let existing = pending.filter { $0.identifier.hasPrefix(BillAlertTime.prefix) }
        // Reserve space for other notification types under iOS's pending notification limit.
        let availableSlots = max(0, 64 - (pending.count - existing.count))
        let upcoming = (enabled && allowed ? BillAlertTime.upcoming(for: bills, after: Date()) : []).prefix(availableSlots)
        let keep = Set(upcoming.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { !keep.contains($0) })
        if !enabled || bills.isEmpty {
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(BillAlertTime.prefix) })
        }

        var failed = false
        for alert in upcoming {
            if existing.contains(where: {
                $0.identifier == alert.id && ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents == alert.components
            }) { continue }

            let content = UNMutableNotificationContent()
            content.title = "Card Ledger"
            content.body = alert.dueThatDay
                ? "A credit card payment is due today. Open Card Ledger to review."
                : "A credit card payment is due soon. Open Card Ledger to review."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: alert.components, repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger)) }
            catch {
                center.removePendingNotificationRequests(withIdentifiers: [alert.id])
                failed = true
            }
        }

        if enabled && !allowed {
            message = "Allow Card Ledger notifications in iOS Settings to receive alerts."
        } else if failed {
            message = "Some bill alerts could not be scheduled. Refresh payment dates to retry."
        } else {
            message = nil
        }
    }
}
