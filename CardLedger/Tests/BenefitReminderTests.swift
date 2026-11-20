import UserNotifications
import XCTest
@testable import CardLedger

@MainActor
private final class MockNotificationCenter: NotificationCenterClient {
    var status: UNAuthorizationStatus = .authorized
    var requestAuthorizationResult = true
    var shouldThrowOnAdd = false
    var pending: [UNNotificationRequest] = []
    var deliveredIDs: [String] = []
    var addedRequests: [UNNotificationRequest] = []
    var removedPendingIDs: [[String]] = []
    var removedDeliveredIDs: [[String]] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        if requestAuthorizationResult {
            status = .authorized
        } else {
            status = .denied
        }
        return requestAuthorizationResult
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] { pending }

    func add(_ request: UNNotificationRequest) async throws {
        if shouldThrowOnAdd {
            throw NSError(domain: "MockNotificationCenter", code: 1)
        }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIDs.append(identifiers)
        let drop = Set(identifiers)
        pending.removeAll { drop.contains($0.identifier) }
    }

    func deliveredNotificationIdentifiers() async -> [String] { deliveredIDs }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIDs.append(identifiers)
        let drop = Set(identifiers)
        deliveredIDs.removeAll { drop.contains($0) }
    }
}

final class BenefitReminderTests: XCTestCase {
    private let eastern = TimeZone(identifier: "America/Toronto")!

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    private func makePeriod(
        cardID: String = "card-1",
        cardNickname: String = "Secret Platinum Card",
        ruleID: String = "dining-credit",
        ruleName: String = "Secret Dining Credit",
        start: Date = Day.make(2026, 11, 1),
        end: Date = Day.make(2026, 12, 1),
        capMinor: Int = 2500,
        confirmedMinor: Int = 0,
        connection: ConnectionState = .plaid(institution: "Amex"),
        connectionID: String? = "conn-1",
        lastSync: Date?
    ) -> BenefitPeriod {
        let card = Card(
            id: cardID,
            nickname: cardNickname,
            productID: "amex-platinum-us",
            mask: "10088",
            openedOn: Day.make(2025, 1, 1),
            renewal: nil,
            connection: connection,
            lastSync: lastSync,
            historyStart: Day.make(2025, 1, 1),
            connectionID: connectionID
        )
        let rule = BenefitRule(
            id: ruleID,
            version: 1,
            name: ruleName,
            cap: Money(capMinor, .usd),
            period: .monthly,
            merchantKeywords: ["resy"],
            eligibleCategories: [.dining],
            creditDescriptor: "RESY CREDIT",
            creditLagDays: 5,
            requiresEnrollment: false,
            sourceURL: URL(string: "https://example.com")!,
            notes: ""
        )
        return BenefitPeriod(
            id: "\(ruleID)|\(cardID)|\(Day.key(start))",
            card: card,
            rule: rule,
            start: start,
            end: end,
            confirmed: Money(confirmedMinor, .usd),
            awaiting: .zero(.usd),
            allocations: [],
            eligiblePurchases: [],
            pendingPurchases: [],
            refunds: []
        )
    }

    @MainActor
    func testSchedulesAt9AMForSelectedOffsetsWithGenericLockScreenCopy() async {
        let now = makeDate(2026, 11, 10, hour: 8)
        let today = Day.make(2026, 11, 10)
        // Two different credits ending on Nov 30 (lastDay = 2026-11-30) should coalesce per offset.
        let p1 = makePeriod(cardID: "card-1", ruleID: "rule-a", lastSync: now)
        let p2 = makePeriod(cardID: "card-2", cardNickname: "Private Sapphire", ruleID: "rule-b", ruleName: "Hotel Credit", lastSync: now)

        let center = MockNotificationCenter()
        let notifications = BenefitNotifications(center: center)
        await notifications.apply([p1, p2], offsets: [14, 7, 2], enabled: true, now: now, today: today, timeZone: eastern)

        XCTAssertNil(notifications.message)
        XCTAssertEqual(center.pending.count, 3)

        let byID = Dictionary(uniqueKeysWithValues: center.pending.map { ($0.identifier, $0) })
        let expectedDates: [(String, Int, Int, Int)] = [
            ("benefit-deadline.2026-11-30.14", 2026, 11, 16),
            ("benefit-deadline.2026-11-30.7", 2026, 11, 23),
            ("benefit-deadline.2026-11-30.2", 2026, 11, 28),
        ]
        for (id, y, m, d) in expectedDates {
            let req = try? XCTUnwrap(byID[id])
            XCTAssertNotNil(req, "Missing scheduled request \(id)")
            let trigger = req?.trigger as? UNCalendarNotificationTrigger
            XCTAssertEqual(trigger?.dateComponents.year, y)
            XCTAssertEqual(trigger?.dateComponents.month, m)
            XCTAssertEqual(trigger?.dateComponents.day, d)
            XCTAssertEqual(trigger?.dateComponents.hour, 9)
            XCTAssertEqual(trigger?.dateComponents.minute, 0)
            XCTAssertEqual(req?.content.title, "Card Ledger")
            // Generic lock-screen copy must never leak card name, benefit name, or amounts.
            let body = req?.content.body ?? ""
            XCTAssertFalse(body.contains("Secret Platinum"))
            XCTAssertFalse(body.contains("Private Sapphire"))
            XCTAssertFalse(body.contains("Dining"))
            XCTAssertFalse(body.contains("Hotel"))
            XCTAssertFalse(body.contains("25"))
        }
    }

    @MainActor
    func testTurningOffsetOffCancelsOnlyThatOffsetAndPreservesBillAlerts() async {
        let now = makeDate(2026, 11, 10, hour: 8)
        let today = Day.make(2026, 11, 10)
        let period = makePeriod(lastSync: now)

        let center = MockNotificationCenter()
        let billContent = UNMutableNotificationContent()
        billContent.title = "Card Ledger"
        billContent.body = "A credit card payment is due soon."
        let billTrigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(year: 2026, month: 11, day: 25, hour: 9, minute: 0),
            repeats: false
        )
        center.pending = [
            UNNotificationRequest(identifier: "bill-payment.card-1.3", content: billContent, trigger: billTrigger),
            UNNotificationRequest(identifier: "statement-bill.card-2.2026-11-28.3", content: billContent, trigger: billTrigger),
        ]
        center.deliveredIDs = [
            "benefit-deadline.2026-10-31.2",
            "bill-payment.card-1.0",
        ]

        let notifications = BenefitNotifications(center: center)
        await notifications.apply([period], offsets: [14, 7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(Set(center.pending.map(\.identifier)), Set([
            "bill-payment.card-1.3",
            "statement-bill.card-2.2026-11-28.3",
            "benefit-deadline.2026-11-30.14",
            "benefit-deadline.2026-11-30.7",
            "benefit-deadline.2026-11-30.2",
        ]))

        // Turn off the 14-day toggle: only *.14 must be cancelled.
        await notifications.apply([period], offsets: [7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(Set(center.pending.map(\.identifier)), Set([
            "bill-payment.card-1.3",
            "statement-bill.card-2.2026-11-28.3",
            "benefit-deadline.2026-11-30.7",
            "benefit-deadline.2026-11-30.2",
        ]))
        XCTAssertTrue(center.removedPendingIDs.last?.contains("benefit-deadline.2026-11-30.14") == true)

        // Turn off all offsets: pending and delivered benefit-deadline.* alerts are removed; bill alerts stay.
        await notifications.apply([period], offsets: [], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(Set(center.pending.map(\.identifier)), Set([
            "bill-payment.card-1.3",
            "statement-bill.card-2.2026-11-28.3",
        ]))
        XCTAssertEqual(center.deliveredIDs, ["bill-payment.card-1.0"])
    }

    @MainActor
    func testFullyUsedBenefitCancelsScheduledReminders() async {
        let now = makeDate(2026, 11, 20, hour: 8)
        let today = Day.make(2026, 11, 20)
        let open = makePeriod(confirmedMinor: 0, lastSync: now)
        let used = makePeriod(confirmedMinor: 2500, lastSync: now)

        let center = MockNotificationCenter()
        let notifications = BenefitNotifications(center: center)
        await notifications.apply([open], offsets: [7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(center.pending.count, 2)

        await notifications.apply([used], offsets: [7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertTrue(center.pending.isEmpty, "Once the credit is fully used, its reminders must be cancelled")
    }

    @MainActor
    func testStaleDataUsesRefreshWordingAndFreshSyncReplacesPendingBody() async {
        // Deadline is Nov 30, so the 2-day reminder fires Nov 28 at 9:00 AM.
        let now = makeDate(2026, 11, 28, hour: 7) // 2 hours before the 9:00 AM fire time
        let today = Day.make(2026, 11, 28)

        // 1. Stale sync (30 hours old at fire time) -> stale wording required by CL-21.
        let staleSync = makeDate(2026, 11, 27, hour: 3)
        let stalePeriod = makePeriod(lastSync: staleSync)
        let center = MockNotificationCenter()
        let notifications = BenefitNotifications(center: center)

        await notifications.apply([stalePeriod], offsets: [2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending[0].content.body, BenefitAlertTime.staleBody)
        XCTAssertTrue(center.pending[0].content.body.contains("may already be used. Open Card Ledger to refresh."))

        // 2. Fresh sync (3 hours old at fire time) -> must replace the existing pending request with fresh wording.
        let freshSync = makeDate(2026, 11, 28, hour: 6)
        let freshPeriod = makePeriod(lastSync: freshSync)
        await notifications.apply([freshPeriod], offsets: [2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending[0].content.body, BenefitAlertTime.freshBody)
        XCTAssertFalse(center.pending[0].content.body.contains("may already be used"))

        // 3. Linked card that never synced -> stale wording.
        let neverSynced = makePeriod(lastSync: nil)
        let neverAlerts = BenefitAlertTime.upcoming(for: [neverSynced], offsets: [2], after: now, today: today, timeZone: eastern)
        XCTAssertEqual(neverAlerts.count, 1)
        XCTAssertTrue(neverAlerts[0].isStaleData)

        // 4. Reminder firing > 24h after a fresh sync (scheduled 5 days ahead) -> stale wording if app is never reopened.
        let fiveDaysEarlier = makeDate(2026, 11, 23, hour: 10)
        let scheduledAhead = makePeriod(lastSync: fiveDaysEarlier)
        let aheadAlerts = BenefitAlertTime.upcoming(
            for: [scheduledAhead],
            offsets: [2],
            after: fiveDaysEarlier,
            today: Day.make(2026, 11, 23),
            timeZone: eastern
        )
        XCTAssertEqual(aheadAlerts.count, 1)
        XCTAssertTrue(aheadAlerts[0].isStaleData)
        XCTAssertTrue(aheadAlerts[0].body.contains("may already be used. Open Card Ledger to refresh."))
    }

    @MainActor
    func testRespects64NotificationCeilingAndPermissionTransitions() async {
        let now = makeDate(2026, 11, 10, hour: 8)
        let today = Day.make(2026, 11, 10)
        let period = makePeriod(lastSync: now)

        let center = MockNotificationCenter()
        let fillerContent = UNMutableNotificationContent()
        fillerContent.title = "Card Ledger"
        fillerContent.body = "Bill"
        let fillerTrigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(year: 2026, month: 11, day: 20, hour: 9, minute: 0),
            repeats: false
        )
        center.pending = (0..<63).map { i in
            UNNotificationRequest(identifier: "bill-payment.c\(i).3", content: fillerContent, trigger: fillerTrigger)
        }

        let notifications = BenefitNotifications(center: center)
        await notifications.apply([period], offsets: [14, 7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(center.pending.count, 64, "Must never exceed iOS 64-notification cap")
        XCTAssertEqual(center.pending.filter { $0.identifier.hasPrefix(BenefitAlertTime.prefix) }.count, 1)

        // When permission is denied, pending benefit notifications are removed and guidance is surfaced.
        center.pending = []
        center.status = .authorized
        await notifications.apply([period], offsets: [7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(center.pending.count, 2)

        center.status = .denied
        await notifications.apply([period], offsets: [7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertNotNil(notifications.message)
        XCTAssertFalse(notifications.needsAuthorizationPrompt)

        // When permission is not yet determined, prompt flag is set so Settings can offer an Allow button.
        center.status = .notDetermined
        await notifications.apply([period], offsets: [7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertTrue(notifications.needsAuthorizationPrompt)
        XCTAssertNotNil(notifications.message)

        // Once allowed, reminders reschedule and the message clears.
        center.status = .authorized
        await notifications.apply([period], offsets: [7, 2], enabled: true, now: now, today: today, timeZone: eastern)
        XCTAssertEqual(center.pending.count, 2)
        XCTAssertNil(notifications.message)
        XCTAssertFalse(notifications.needsAuthorizationPrompt)
    }

    @MainActor
    func testStorePersistsReminderOffsetsAcrossReload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cl-reminders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = Store(today: Day.make(2026, 11, 20), databaseDirectory: dir)
        XCTAssertEqual(store.reminderOffsets, [7, 2])

        await store.setReminderOffset(14, enabled: true)
        await store.setReminderOffset(7, enabled: false)
        XCTAssertEqual(store.reminderOffsets, [14, 2])

        let reloaded = Store(today: Day.make(2026, 11, 20), databaseDirectory: dir)
        XCTAssertEqual(reloaded.reminderOffsets, [14, 2])
    }

    func testCardsWithoutABankFeedNeverAskForARefresh() {
        // Deadline Nov 30; the 2-day reminder fires Nov 28 at 9:00 AM, five days after `now`.
        let now = makeDate(2026, 11, 23, hour: 10)
        let today = Day.make(2026, 11, 23)
        let manual = makePeriod(cardID: "manual-1", connection: .manual, connectionID: nil, lastSync: nil)
        let statement = makePeriod(cardID: "pdf-1", connection: .pdf, connectionID: nil, lastSync: nil)

        for period in [manual, statement] {
            let ahead = BenefitAlertTime.upcoming(for: [period], offsets: [2], after: now, today: today, timeZone: eastern)
            XCTAssertEqual(ahead.map(\.wording), [.noFeed])
            XCTAssertEqual(ahead[0].body, BenefitAlertTime.noFeedBody)
            XCTAssertTrue(ahead[0].body.contains("may already be used"))
            XCTAssertFalse(ahead[0].body.contains("refresh"))
        }

        // Scheduled within a day of firing, a card without a feed gets the plain wording.
        let soon = makeDate(2026, 11, 28, hour: 7)
        let fresh = BenefitAlertTime.upcoming(for: [manual], offsets: [2], after: soon, today: Day.make(2026, 11, 28), timeZone: eastern)
        XCTAssertEqual(fresh.map(\.wording), [.fresh])

        // One alert covers both cards when they share a deadline; a linked card with old data decides the advice.
        let linked = makePeriod(cardID: "linked-1", lastSync: makeDate(2026, 11, 20, hour: 8))
        let shared = BenefitAlertTime.upcoming(for: [manual, linked], offsets: [2], after: now, today: today, timeZone: eastern)
        XCTAssertEqual(shared.map(\.wording), [.staleFeed])
    }
}
