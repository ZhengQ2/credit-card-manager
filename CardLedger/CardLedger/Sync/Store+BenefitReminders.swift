import Foundation

@MainActor
extension Store {
    /// Toggles one benefit-deadline offset (14, 7, or 2 days) and updates local notifications.
    /// Requests iOS notification permission when turning an offset on for a live ledger.
    func setReminderOffset(_ offset: Int, enabled: Bool) async {
        if enabled {
            reminderOffsets.insert(offset)
            if mode == .live, !(await benefitNotifications.hasAccess()) {
                await benefitNotifications.requestAccess()
            }
        } else {
            reminderOffsets.remove(offset)
        }
        updateBenefitNotifications(force: true)
    }

    /// Prompts for iOS notification authorization and immediately reschedules benefit reminders.
    @discardableResult
    func requestBenefitNotificationAccess() async -> Bool {
        let granted = await benefitNotifications.requestAccess()
        updateBenefitNotifications(force: true)
        return granted
    }

    /// Reconciles scheduled `benefit-deadline.*` notifications with the current open benefit deadlines
    /// and selected offsets. Never schedules alerts for sample data.
    func updateBenefitNotifications(force: Bool = false, now: Date = Date()) {
        let isLive = mode == .live
        let periods = isLive ? activeDeadlines : []
        let offsets = isLive ? reminderOffsets : []
        let planned = BenefitAlertTime.upcoming(for: periods, offsets: offsets, after: now, today: today)
        let signature = [Day.key(today), isLive ? "live" : "sample"]
            + offsets.sorted().map { "o:\($0)" }
            + planned.map { "\($0.id)|\($0.wording.rawValue)" }
        let needsRetry = benefitNotifications.message != nil
        guard force || needsRetry || signature != lastBenefitAlertSignature else { return }
        lastBenefitAlertSignature = signature
        benefitNotifications.update(periods, offsets: offsets, enabled: isLive, now: now, today: today)
    }
}
