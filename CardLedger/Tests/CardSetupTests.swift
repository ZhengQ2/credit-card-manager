import XCTest
@testable import CardLedger

final class CardSetupTests: XCTestCase {
    func testCatalogDecodesAuditedCoverageByMarket() {
        XCTAssertEqual(Catalog.exactProduct("capone-quicksilver")?.plaidSupport, .oauth)
        XCTAssertEqual(Catalog.exactProduct("capone-ca-platinum")?.plaidSupport, .limited)
        XCTAssertEqual(Catalog.exactProduct("amex-cobalt-ca")?.plaidSupport, .credential)
        XCTAssertNil(Catalog.exactProduct("custom-us")?.plaidSupport)

        let unsupported = Catalog.products.filter(\.suggestsStatementImport)
        XCTAssertEqual(Set(unsupported.map(\.id)), [
            "apple-card", "home-trust-preferred", "mbna-rewards-we", "mbna-true-line", "mbna-rewards-plat",
        ])
        XCTAssertEqual(Catalog.products.filter { $0.plaidSupport == .limited }.count, 18)
        XCTAssertTrue(Catalog.products.filter { $0.issuer != "Other" }.allSatisfy { $0.plaidSupport != nil })
    }

    @MainActor
    func testWatchlistNotesPersistAndEstimatesDoNotChangeWallet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(databaseDirectory: directory)
        let wallet = store.rewards.cards
        let count = store.fiveTwentyFourCount

        XCTAssertThrowsError(try store.saveWatchlistEntry(productID: "custom-ca", note: "Generic"))
        try store.saveWatchlistEntry(productID: "amex-cobalt-ca", note: "Compare groceries")
        try store.saveWatchlistEntry(productID: "amex-cobalt-ca", note: " Compare groceries and dining ")
        XCTAssertEqual(store.rewards.cards, wallet)
        XCTAssertEqual(store.fiveTwentyFourCount, count)
        let reopened = Store(databaseDirectory: directory)
        XCTAssertEqual(reopened.watchlist, [WatchlistEntry(productID: "amex-cobalt-ca", note: "Compare groceries and dining")])
        XCTAssertTrue(try XCTUnwrap(reopened.repo).loadCards().isEmpty)

        let quotes = reopened.watchlistRewards.rank(category: .groceries, currency: .cad,
                                                   amount: Money(10_000, .cad), usage: [:], today: reopened.today)
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(quotes.first?.product.id, "amex-cobalt-ca")
        XCTAssertEqual(quotes.first?.multiplier, 5)
        XCTAssertFalse(reopened.cards.contains { $0.id == quotes.first?.card.id })

        try reopened.removeWatchlistEntry(productID: "amex-cobalt-ca")
        XCTAssertTrue(Store(databaseDirectory: directory).watchlist.isEmpty)
    }

    @MainActor
    func testManualStatementCreditPersistsAndReducesEffectiveFee() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(databaseDirectory: directory)
        store.addManualCard(nickname: "Test card", productID: "amex-platinum-us", mask: nil,
                            openedOn: Day.addMonths(-2, to: store.today), renewal: nil)
        let card = try XCTUnwrap(store.cards.first)
        XCTAssertEqual(card.connection, .manual)
        let period = try XCTUnwrap(store.benefits.periods.first {
            $0.card.id == card.id && $0.rule.id == "plat-entertainment" && $0.isCurrent(today: store.today)
        })
        XCTAssertTrue(period.canLogStatementCredit)
        let fee = store.effectiveFee(card)
        XCTAssertFalse(store.logUsage(periodID: period.id, amount: Money(1_200, .cad), usedOn: store.today, note: ""))
        XCTAssertFalse(store.logUsage(periodID: period.id, amount: Money(1_200, .usd), usedOn: Day.add(1, to: store.today), note: ""))
        XCTAssertFalse(store.logUsage(periodID: period.id, amount: Money(2_501, .usd), usedOn: store.today, note: ""))
        XCTAssertTrue(store.logUsage(periodID: period.id, amount: Money(1_200, .usd), usedOn: store.today, note: "Issuer statement"))
        XCTAssertEqual(store.benefits.period(period.id)?.confirmed, Money(1_200, .usd))
        XCTAssertEqual(store.effectiveFee(card), fee - Money(1_200, .usd))

        let reopened = Store(databaseDirectory: directory)
        let record = try XCTUnwrap(reopened.usage(for: period.id).first)
        XCTAssertEqual(record.usedOn, store.today)
        XCTAssertEqual(reopened.effectiveFee(card), fee - Money(1_200, .usd))
        reopened.deleteUsage(record.id)
        XCTAssertEqual(reopened.effectiveFee(card), fee)
    }

    func testMatchedIssuerCreditTakesPrecedenceOverManualLog() throws {
        let today = Day.make(2026, 11, 20)
        let start = Day.startOfMonth(today)
        let card = Card(id: "manual-card", nickname: "Test card", productID: "amex-platinum-us",
                        mask: nil, openedOn: start, renewal: nil, connection: .manual, lastSync: nil, historyStart: start)
        let initial = BenefitEngine.evaluate(cards: [card], transactions: [], decisions: [:], today: today)
        let period = try XCTUnwrap(initial.periods.first { $0.rule.id == "plat-entertainment" })
        let manual = UsageLog(id: "manual-credit", periodID: period.id, amount: Money(1_200, .usd),
                              usedOn: Day.add(2, to: start), note: "")
        let credit = Transaction(id: "issuer-credit", cardID: card.id, amount: Money(-900, .usd), posted: today,
                                 authorized: nil, merchant: "Issuer", originalDescription: "DIGITAL ENTERTAINMENT CREDIT",
                                 category: .streaming, kind: .issuerCredit, provenance: .pdf)
        let result = BenefitEngine.evaluate(cards: [card], transactions: [credit], decisions: [credit.id: .assign(periodID: period.id)],
                                            today: today, usage: [period.id: manual.amount.minor])
        XCTAssertEqual(result.period(period.id)?.confirmed, Money(900, .usd))
        XCTAssertEqual(result.period(period.id)?.canLogStatementCredit, false)
        XCTAssertEqual(BenefitEngine.creditsRedeemed(card: card, periods: result.periods, transactions: [credit],
                                                    usageLogs: [manual], since: start, today: today), Money(900, .usd))
    }

    func testOlderInAppLogKeepsItsFeeAccounting() throws {
        let start = Day.make(2026, 10, 1)
        let today = Day.make(2026, 11, 20)
        let card = Card(id: "test-card", nickname: "Test card", productID: "amex-platinum-us",
                        mask: nil, openedOn: start, renewal: nil, connection: .manual, lastSync: nil, historyStart: start)
        let result = BenefitEngine.evaluate(cards: [card], transactions: [], decisions: [:], today: today)
        let period = try XCTUnwrap(result.periods.first { $0.rule.id == "plat-uber-cash" && $0.start == start })
        let legacy = UsageLog(id: "legacy", periodID: period.id, amount: Money(500, .usd), usedOn: today, note: "")
        XCTAssertEqual(BenefitEngine.creditsRedeemed(card: card, periods: result.periods, transactions: [],
                                                    usageLogs: [legacy], since: start, today: today), Money(500, .usd))
    }
}
