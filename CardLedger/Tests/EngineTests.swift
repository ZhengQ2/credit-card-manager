import Foundation

private var failures = 0
private var passed = 0

private func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        fputs("FAIL [\(URL(fileURLWithPath: file).lastPathComponent):\(line)]: \(message)\n", stderr)
    }
}

private func runTests() {
    // 1. Day.toLocal / Day.fromLocal round-trip in Western Hemisphere timezone (EST, UTC-5)
    let sampleDay = Day.make(2026, 11, 19)
    let local = Day.toLocal(sampleDay)
    let roundTripped = Day.fromLocal(local)
    check(roundTripped == sampleDay, "Day.toLocal/fromLocal round-trip must preserve 2026-11-19 (got \(Day.key(roundTripped)))")

    // 2. PlaidMapping classification
    let amexReimb = RemoteTransaction(
        id: "t1", accountId: "a1", amountMinor: -20000, currency: "USD", currencyIsOfficial: true,
        date: "2026-11-10", authorizedDate: nil, name: "AMEX Airline Fee Reimbursement",
        merchantName: "American Express", originalDescription: "AMEX AIRLINE FEE REIMBURSEMENT",
        categoryPrimary: "TRAVEL", categoryDetailed: "TRAVEL_FLIGHTS", merchantCategoryCode: nil,
        pending: false, pendingTransactionId: nil
    )
    check(PlaidMapping.kind(amexReimb) == .issuerCredit, "AMEX Airline Fee Reimbursement with merchantName must be .issuerCredit")

    let stmtCredit = RemoteTransaction(
        id: "t2", accountId: "a1", amountMinor: -2500, currency: "USD", currencyIsOfficial: true,
        date: "2026-11-10", authorizedDate: nil, name: "Statement Credit",
        merchantName: "American Express", originalDescription: "PLATINUM STATEMENT CREDIT",
        categoryPrimary: "ENTERTAINMENT", categoryDetailed: nil, merchantCategoryCode: nil,
        pending: false, pendingTransactionId: nil
    )
    check(PlaidMapping.kind(stmtCredit) == .issuerCredit, "Statement credit with merchantName must be .issuerCredit")

    let feeRefund = RemoteTransaction(
        id: "t3", accountId: "a1", amountMinor: -89500, currency: "USD", currencyIsOfficial: true,
        date: "2026-11-10", authorizedDate: nil, name: "Annual Fee Reversal",
        merchantName: "American Express", originalDescription: "ANNUAL MEMBERSHIP FEE REVERSAL",
        categoryPrimary: "BANK_FEES", categoryDetailed: nil, merchantCategoryCode: nil,
        pending: false, pendingTransactionId: nil
    )
    check(PlaidMapping.kind(feeRefund) != .fee, "Negative BANK_FEES must never be classified as .fee")

    // 3. BenefitEngine: isolated open balances across overlapping rules, CR matching, no future-purchase matching,
    //    no contradictory capReached on reimbursed purchase, multi-period ambiguity goes to review, 12-month credit window.
    let today = Day.make(2026, 11, 19)
    let goldCard = Card(
        id: "gold-1", nickname: "Gold", productID: "amex-gold-us", mask: "1001",
        openedOn: Day.make(2025, 1, 10), renewal: nil, connection: .manual,
        lastSync: nil, historyStart: Day.make(2026, 9, 1), openDateStatus: .confirmed
    )
    let cfPurchase = Transaction(
        id: "p-cf", cardID: "gold-1", amount: .dollars(50, .usd), posted: Day.make(2026, 10, 5), authorized: nil,
        merchant: "Cheesecake Factory", originalDescription: "CHEESECAKE FACTORY", category: .dining, kind: .purchase
    )
    let cfRefund = Transaction(
        id: "r-cf", cardID: "gold-1", amount: .dollars(-50, .usd), posted: Day.make(2026, 10, 6), authorized: nil,
        merchant: "Cheesecake Factory", originalDescription: "CHEESECAKE FACTORY REFUND", category: .dining, kind: .refund
    )
    let resyCr = Transaction(
        id: "c-resy", cardID: "gold-1", amount: .dollars(-50, .usd), posted: Day.make(2026, 10, 8), authorized: nil,
        merchant: "American Express", originalDescription: "AMEX RESY CR", category: .other, kind: .issuerCredit
    )
    let goldProduct = Catalog.product("amex-gold-us")
    let matchedResy = BenefitEngine.namedRule(for: resyCr, in: goldProduct.benefits.filter { $0.redemption == .statementCredit })
    check(matchedResy?.id == "gold-resy", "AMEX RESY CR should match gold-resy rule (got \(matchedResy?.id ?? "nil"))")

    // Refund of Cheesecake Factory must zero out open amount on BOTH gold-dining and gold-resy without one wiping out the other.
    let overlapResult = BenefitEngine.evaluate(cards: [goldCard], transactions: [cfPurchase, cfRefund], decisions: [:], today: today)
    let octDining = overlapResult.periods.first { $0.rule.id == "gold-dining" && $0.start == Day.make(2026, 10, 1) }
    check(octDining?.awaiting.minor == 0, "Refunded Cheesecake Factory should leave 0 awaiting on gold-dining (got \(octDining?.awaiting.minor ?? -1))")

    // Ambiguous multi-period credit (purchases in Oct and Nov, credit posts Nov 2) must go to review.
    let brilliantCard = Card(
        id: "bri-1", nickname: "Brilliant", productID: "amex-marriott-brilliant", mask: "3002",
        openedOn: Day.make(2025, 1, 1), renewal: nil, connection: .manual,
        lastSync: nil, historyStart: Day.make(2026, 10, 1), openDateStatus: .confirmed
    )
    let octDinner = Transaction(
        id: "d-oct", cardID: "bri-1", amount: .dollars(84.20, .usd), posted: Day.make(2026, 10, 30), authorized: nil,
        merchant: "Sushi", originalDescription: "SUSHI NY", category: .dining, kind: .purchase
    )
    let novDinner = Transaction(
        id: "d-nov", cardID: "bri-1", amount: .dollars(40, .usd), posted: Day.make(2026, 11, 1), authorized: nil,
        merchant: "Pizza", originalDescription: "PIZZA NY", category: .dining, kind: .purchase
    )
    let novCredit = Transaction(
        id: "c-nov2", cardID: "bri-1", amount: .dollars(-25, .usd), posted: Day.make(2026, 11, 2), authorized: nil,
        merchant: "American Express", originalDescription: "BRILLIANT DINING CREDIT", category: .other, kind: .issuerCredit
    )
    let ambig = BenefitEngine.evaluate(cards: [brilliantCard], transactions: [octDinner, novDinner, novCredit], decisions: [:], today: today)
    check(ambig.reviews.count == 1 && ambig.reviews[0].candidatePeriodIDs.count == 2,
          "Multi-period ambiguous credit must go to review with 2 candidates (got \(ambig.reviews.count) reviews)")

    // Single dinner ($84.20) reimbursed by $25 credit must NOT also get .capReached.
    let singleReimb = BenefitEngine.evaluate(cards: [brilliantCard], transactions: [octDinner, novCredit], decisions: [:], today: today)
    let dinnerLinks = singleReimb.evidence["d-oct"] ?? []
    check(dinnerLinks.contains { $0.status == .confirmed }, "Dinner should have .confirmed evidence")
    check(!dinnerLinks.contains { $0.status == .capReached }, "Reimbursed dinner must NOT also get contradictory .capReached")

    // Credit posted Nov 2 must NOT match a purchase posted Nov 10.
    let futureDinner = Transaction(
        id: "d-nov10", cardID: "bri-1", amount: .dollars(40, .usd), posted: Day.make(2026, 11, 10), authorized: nil,
        merchant: "Late Dinner", originalDescription: "LATE DINNER", category: .dining, kind: .purchase
    )
    let noFutureMatch = BenefitEngine.evaluate(cards: [brilliantCard], transactions: [novCredit, futureDinner], decisions: [:], today: today)
    let nov10Links = noFutureMatch.evidence["d-nov10"] ?? []
    check(!nov10Links.contains { $0.status == .confirmed }, "Nov 2 credit must not mark Nov 10 purchase as reimbursed")

    // creditsRedeemed over 12 months must NOT double-count 2025 + 2026 annual credits.
    let platCard = Card(
        id: "plat-1", nickname: "Platinum", productID: "amex-platinum-us", mask: "1008",
        openedOn: Day.make(2024, 1, 1), renewal: nil, connection: .manual,
        lastSync: nil, historyStart: Day.make(2025, 1, 1), openDateStatus: .confirmed
    )
    let clear2025 = Transaction(
        id: "cl-25", cardID: "plat-1", amount: .dollars(219, .usd), posted: Day.make(2025, 2, 1), authorized: nil,
        merchant: "Clear", originalDescription: "CLEARME.COM", category: .other, kind: .purchase
    )
    let clearCr2025 = Transaction(
        id: "clcr-25", cardID: "plat-1", amount: .dollars(-219, .usd), posted: Day.make(2025, 2, 5), authorized: nil,
        merchant: "American Express", originalDescription: "PLATINUM CLEAR CREDIT", category: .other, kind: .issuerCredit
    )
    let clear2026 = Transaction(
        id: "cl-26", cardID: "plat-1", amount: .dollars(219, .usd), posted: Day.make(2026, 2, 1), authorized: nil,
        merchant: "Clear", originalDescription: "CLEARME.COM", category: .other, kind: .purchase
    )
    let clearCr2026 = Transaction(
        id: "clcr-26", cardID: "plat-1", amount: .dollars(-219, .usd), posted: Day.make(2026, 2, 5), authorized: nil,
        merchant: "American Express", originalDescription: "PLATINUM CLEAR CREDIT", category: .other, kind: .issuerCredit
    )
    let platTxs = [clear2025, clearCr2025, clear2026, clearCr2026]
    let platEval = BenefitEngine.evaluate(cards: [platCard], transactions: platTxs, decisions: [:], today: today)
    let redeemed12m = BenefitEngine.creditsRedeemed(
        card: platCard, periods: platEval.periods, transactions: platTxs,
        since: Day.addMonths(-12, to: today), today: today
    )
    check(redeemed12m.minor == 21900, "12-month credits redeemed must be $219 (only 2026), not $438 (got \(redeemed12m.formatted))")

    // BenefitRule.isEligible checks originalDescription AND respects word boundaries for short keywords.
    let platProduct = Catalog.product("amex-platinum-us")
    let clearRule = platProduct.benefits.first { $0.id == "plat-clear" }!
    let entRule = platProduct.benefits.first { $0.id == "plat-entertainment" }!
    let clearwaterTx = Transaction(
        id: "cw", cardID: "plat-1", amount: .dollars(20, .usd), posted: today, authorized: nil,
        merchant: "Clearwater Cafe", originalDescription: "CLEARWATER CAFE", category: .dining, kind: .purchase
    )
    let ytTx = Transaction(
        id: "yt", cardID: "plat-1", amount: .dollars(13.99, .usd), posted: today, authorized: nil,
        merchant: "Google", originalDescription: "GOOGLE *YOUTUBEPREMIUM", category: .streaming, kind: .purchase
    )
    check(!clearRule.isEligible(clearwaterTx), "plat-clear must not match Clearwater Cafe")
    check(clearRule.isEligible(clear2026), "plat-clear must match CLEARME.COM")
    check(entRule.isEligible(ytTx), "plat-entertainment must match GOOGLE *YOUTUBEPREMIUM in originalDescription")

    // Renewal for newly opened card in current month must be +12 months, not opening day.
    let newCard = Card(
        id: "new-1", nickname: "New", productID: "amex-platinum-us", mask: "9999",
        openedOn: Day.make(2026, 11, 15), renewal: nil, connection: .manual,
        lastSync: nil, historyStart: Day.make(2026, 11, 15), openDateStatus: .confirmed
    )
    let newRenewal = BenefitEngine.renewal(for: newCard, transactions: [], today: today)
    check(newRenewal?.date == Day.make(2027, 11, 15), "New card renewal must be 2027-11-15 (got \(newRenewal.map { Day.key($0.date) } ?? "nil"))")

    // 4. RewardsEngine: over-cap refund math, pending exclusion, empty cards safety, BCE split caps.
    let rewards = RewardsEngine(cards: [goldCard], assumptions: Assumptions())
    let bigGrocery = Transaction(
        id: "g1", cardID: "gold-1", amount: .dollars(25100, .usd), posted: Day.make(2026, 5, 1), authorized: nil,
        merchant: "Whole Foods", originalDescription: "WHOLE FOODS", category: .groceries, kind: .purchase
    )
    let pendingGrocery = Transaction(
        id: "g-pend", cardID: "gold-1", amount: .dollars(500, .usd), posted: Day.make(2026, 5, 2), authorized: nil,
        merchant: "Whole Foods", originalDescription: "WHOLE FOODS", category: .groceries, kind: .purchase, pending: true
    )
    let usage = rewards.capUsage(from: [bigGrocery, pendingGrocery], through: today)
    // Usage must ignore pendingGrocery (should be 2510000, not 2560000).
    let refundOverCap = rewards.quote(card: goldCard, amount: .dollars(-100, .usd), category: .groceries, merchant: "Whole Foods", date: Day.make(2026, 5, 3), usage: usage)
    check(abs(refundOverCap.points - (-100.0)) < 0.01, "Over-cap $100 grocery refund should reverse 1x (-100 pts), not 4x (got \(refundOverCap.points))")

    let emptyReplay = RewardsEngine(cards: [], assumptions: Assumptions()).replay([bigGrocery], currency: .usd)
    check(emptyReplay.lines.isEmpty, "Replay with empty cards must not crash")

    func airfare(_ id: String, card: Card, day: Int, dollars: Double, authorizedDay: Int? = nil) -> Transaction {
        Transaction(id: id, cardID: card.id, amount: .dollars(dollars, .usd), posted: Day.make(2026, 11, day),
                    authorized: authorizedDay.map { Day.make(2026, 11, $0) }, merchant: "Example Air", originalDescription: "EXAMPLE AIR",
                    category: .flights, kind: dollars < 0 ? .refund : .purchase)
    }
    let earlyFlight = airfare("early-flight", card: goldCard, day: 10, dollars: 500)
    let laterFlight = airfare("later-flight", card: newCard, day: 16, dollars: 500)
    let flightRefund = airfare("flight-refund", card: goldCard, day: 18, dollars: -500)
    let flightRewards = RewardsEngine(cards: [goldCard, newCard], assumptions: Assumptions())
    let flightReplay = flightRewards.replay([earlyFlight, laterFlight, flightRefund], currency: .usd)
    check(flightReplay.lines.map { $0.alternative.card.id } == [goldCard.id, newCard.id, goldCard.id],
          "Replay must exclude cards before their confirmed opening dates and keep refunds on the matching original card's alternative")

    let laterGoldFlight = airfare("later-gold-flight", card: goldCard, day: 17, dollars: 500)
    let matchedRefund = flightRewards.replay([laterGoldFlight, flightRefund], currency: .usd)
    check(matchedRefund.lines.map { $0.alternative.card.id } == [newCard.id, newCard.id],
          "Replay must carry a refund to the alternative when the original card and merchant uniquely match")

    let ambiguousRefund = flightRewards.replay([earlyFlight, laterGoldFlight, flightRefund], currency: .usd)
    check(ambiguousRefund.lines.last?.alternative.card.id == goldCard.id,
          "Replay must keep a refund on the original card when purchases at the merchant went to multiple alternatives")

    let settledLater = airfare("settled-later", card: goldCard, day: 16, dollars: 500, authorizedDay: 14)
    check(flightRewards.replay([settledLater], currency: .usd).lines.first?.alternative.card.id == goldCard.id,
          "Replay must check card availability on the authorization date when it precedes settlement")

    let bce = Catalog.product("amex-bce-us")
    check(bce.earnRules.count == 2 && bce.earnRules.allSatisfy { $0.categories.count == 1 },
          "Amex BCE should model groceries and gas as separate $6k/yr rules")

    // 5. WelcomeOfferEngine: cardCurrency isolation & non-negative fraction & zero-target guard
    let caOffer = WelcomeOffer(
        id: "wo-1", cardID: "ca-1", kind: .bonusEarn, currency: .cad, start: Day.make(2026, 12, 1), months: 3,
        minSpend: nil, points: nil, cash: nil, extraMultiplier: 5, categories: [.groceries], spendCap: nil, notes: "", markedEarned: false
    )
    let unrelatedUSTx = Transaction(
        id: "us-1", cardID: "plat-1", amount: .dollars(100, .usd), posted: Day.make(2026, 11, 18), authorized: nil,
        merchant: "Coffee", originalDescription: "COFFEE", category: .dining, kind: .purchase
    )
    let caProgress = WelcomeOfferEngine.progress(caOffer, transactions: [unrelatedUSTx], today: today, cardCurrency: .cad)
    check(caProgress.spend.currency == .cad, "Uncapped Canadian welcome offer must stay CAD despite newer USD tx")
    check(caProgress.fraction >= 0 && caProgress.fraction <= 1, "Welcome offer fraction must stay in 0...1 before start date")

    let zeroTargetOffer = WelcomeOffer(
        id: "wo-2", cardID: "gold-1", kind: .spendBonus, currency: .usd, start: Day.make(2026, 11, 1), months: 3,
        minSpend: nil, points: 60000, cash: nil, extraMultiplier: nil, categories: [], spendCap: nil, notes: "", markedEarned: false
    )
    let zeroProgress = WelcomeOfferEngine.progress(zeroTargetOffer, transactions: [], today: today, cardCurrency: .usd)
    check(zeroProgress.state != .met, "Offer with nil minSpend must not falsely show .met")

    // 6. NonCreditEngine: multi-year old card advances anchor to current year, tiny spend doesn't overflow Day.add
    let oldAspire = Card(
        id: "asp-old", nickname: "Aspire", productID: "amex-hilton-aspire", mask: "2004",
        openedOn: Day.make(2023, 5, 1), renewal: nil, connection: .manual,
        lastSync: nil, historyStart: Day.make(2026, 1, 1), openDateStatus: .confirmed
    )
    let tinySpend = Transaction(
        id: "tiny", cardID: "asp-old", amount: Money(1, .usd), posted: Day.make(2026, 11, 1), authorized: nil,
        merchant: "Test", originalDescription: "TEST", category: .other, kind: .purchase
    )
    let certStatuses = NonCreditEngine.certificateStatuses(
        card: oldAspire, renewal: nil, certificates: [], transactions: [tinySpend], today: today
    )
    let fnrStatus = certStatuses.first { $0.rule.id == "aspire-fnr" }
    check(fnrStatus?.expectedFrom == Day.make(2026, 5, 1),
          "Card opened 2023-05-01 should anchor renewal award to 2026-05-01 (got \(fnrStatus?.expectedFrom.map(Day.key) ?? "nil"))")

    let surpass = Card(
        id: "surpass", nickname: "Surpass", productID: "amex-hilton-surpass", mask: nil,
        openedOn: Day.make(2025, 1, 1), renewal: nil, connection: .manual,
        lastSync: nil, historyStart: Day.make(2026, 1, 1), openDateStatus: .confirmed
    )
    func spendAwardStatus(_ transactions: [Transaction]) -> CertificateStatus? {
        NonCreditEngine.certificateStatuses(card: surpass, renewal: nil, certificates: [], transactions: transactions, today: today)
            .first { $0.rule.id == "surpass-fnr" }
    }
    let largePurchase = airfare("large-purchase", card: surpass, day: 1, dollars: 15_100)
    let refund = airfare("partial-refund", card: surpass, day: 2, dollars: -500)
    let newPurchase = airfare("new-purchase", card: surpass, day: 3, dollars: 600)
    check(spendAwardStatus([largePurchase, refund])?.pending == false,
          "An unrecorded spend award should no longer be due after a refund drops net spend below its threshold")
    let earnedAgain = spendAwardStatus([largePurchase, refund, newPurchase])
    check(earnedAgain?.pending == true && earnedAgain?.expectedFrom == newPurchase.posted,
          "An award should use the latest qualifying threshold crossing after a refund")

    // 7. Catalog.suggest recognizes Canadian bank aliases (RBC Royal Bank)
    let rbcSuggested = Catalog.suggest(accountName: "Avion Visa Infinite", institution: "Royal Bank of Canada", currency: "CAD")
    check(rbcSuggested.id == "rbc-avion-vi", "Catalog.suggest should match RBC Avion Visa Infinite (got \(rbcSuggested.id))")

    print("EngineTests: \(passed) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

@main
enum EngineTestRunner {
    static func main() {
        runTests()
    }
}
