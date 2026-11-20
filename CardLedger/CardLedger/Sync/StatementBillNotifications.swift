import Observation
import UserNotifications

/// Schedules local iOS payment-due reminders for statement-imported (PDF / CSV) credit card bills.
/// Manages only `statement-bill.*` notification identifiers so Plaid `bill-payment.*` alerts stay independent.
@Observable
@MainActor
final class StatementBillNotifications {
    private(set) var message: String?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    func hasAccess() async -> Bool {
        Self.canSchedule(await center.notificationSettings().authorizationStatus)
    }

    @discardableResult
    func requestAccess() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        if Self.canSchedule(status) {
            message = nil
            return true
        }
        if status == .denied {
            message = "Allow Card Ledger notifications in iOS Settings to receive payment reminders."
            return false
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            message = granted ? nil : "Allow Card Ledger notifications in iOS Settings to receive payment reminders."
            return granted
        } catch {
            message = "Couldn’t request notification access. Try again."
            return false
        }
    }

    private static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    func update(_ bills: [StatementBill], excludingPlaidBills plaidBills: [BillPayment]) {
        let previous = updateTask
        updateTask = Task { [weak self] in
            await previous?.value
            await self?.apply(bills, excludingPlaidBills: plaidBills)
        }
    }

    private func apply(_ bills: [StatementBill], excludingPlaidBills plaidBills: [BillPayment]) async {
        let settings = await center.notificationSettings()
        let allowed = Self.canSchedule(settings.authorizationStatus)
        let pending = await center.pendingNotificationRequests()
        let existing = pending.filter { $0.identifier.hasPrefix(StatementBillAlertTime.prefix) }

        // Respect iOS's 64 pending-notification ceiling without displacing other notification types.
        let availableSlots = max(0, 64 - (pending.count - existing.count))
        let candidates = StatementBillAlertTime.upcoming(for: bills, excludingPlaidBills: plaidBills, after: Date())
        let upcoming = (allowed ? candidates : []).prefix(availableSlots)
        let keep = Set(upcoming.map(\.id))

        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { !keep.contains($0) })
        if candidates.isEmpty {
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(StatementBillAlertTime.prefix) })
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
            do {
                try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
            } catch {
                center.removePendingNotificationRequests(withIdentifiers: [alert.id])
                failed = true
            }
        }

        if !candidates.isEmpty && !allowed {
            message = "Allow Card Ledger notifications in iOS Settings to receive payment reminders."
        } else if failed {
            message = "Some payment reminders could not be scheduled. Open the card to retry."
        } else {
            message = nil
        }
    }
}
