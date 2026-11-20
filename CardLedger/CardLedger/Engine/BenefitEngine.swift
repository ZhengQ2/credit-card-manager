import Foundation

enum AllocationOrigin: String, Hashable { case automatic = "Automatic", owner = "Owner confirmed" }

struct Allocation: Identifiable, Hashable {
    let id: String
    let creditID: String
    let purchaseIDs: [String]
    let amount: Money
    let origin: AllocationOrigin
    let reason: String
}

enum ReviewDecision: Hashable {
    case assign(periodID: String)
    case keepUnmatched
}

enum EvidenceStatus: String, Hashable {
    case pendingPurchase = "Pending purchase"
    case awaitingCredit = "Awaiting credit"
    case confirmed = "Confirmed"
    case needsReview = "Needs review"
    case notCredited = "Not credited"
    case refunded = "Refunded"
    case creditReversal = "Credit reversal"
    /// The period's cap is already used, so no further credit is expected for this purchase.
    case capReached = "Cap reached"
    case unmatched = "Kept unmatched"
}

struct EvidenceLink: Hashable {
    let periodID: String
    let status: EvidenceStatus
    let note: String
}

struct BenefitPeriod: Identifiable, Hashable {
    let id: String
    let card: Card
    let rule: BenefitRule
    let start: Date
    /// Exclusive end.
    let end: Date
    var confirmed: Money
    var awaiting: Money
    var allocations: [Allocation]
    var eligiblePurchases: [Transaction]
    var pendingPurchases: [Transaction]
    var refunds: [Transaction]
    var creditReversals: [Transaction] = []

    var cap: Money { rule.cap(for: start) }
    var remaining: Money { Money(max(0, min(cap.minor, cap.minor - confirmed.minor)), cap.currency) }
    var usesLoggedUsage: Bool {
        rule.redemption == .appCredit || (rule.redemption == .statementCredit && allocations.isEmpty)
    }
    var canLogStatementCredit: Bool {
        guard rule.redemption == .statementCredit, usesLoggedUsage else { return false }
        switch card.connection {
        case .manual, .csv, .pdf, .ofx: return true
        default: return false
        }
    }
    var lastDay: Date { Day.add(-1, to: end) }
    func isCurrent(today: Date) -> Bool { start <= today && today < end }
    func daysLeft(today: Date) -> Int { Day.days(from: today, to: lastDay) }

    enum State: String { case unused = "Unused", awaiting = "Awaiting credit", partial = "Partially used", full = "Fully used" }
    var state: State {
        if remaining.isZero { return .full }
        if awaiting.minor > 0 { return .awaiting }
        if confirmed.minor > 0 { return .partial }
        return .unused
    }

    var windowLabel: String {
        "\(Day.format(start, .dateTime.month(.abbreviated).day())) – \(Day.format(lastDay))"
    }
}

struct ReviewItem: Identifiable, Hashable {
    var id: String { credit.id }
    let credit: Transaction
    let card: Card
    let reason: String
    let candidatePeriodIDs: [String]
    let cappedPeriodIDs: [String]
}

struct BenefitResult {
    var periods: [BenefitPeriod] = []
    var reviews: [ReviewItem] = []
    var evidence: [String: [EvidenceLink]] = [:]

    func period(_ id: String) -> BenefitPeriod? { periods.first { $0.id == id } }
}

/// Matches issuer credits to eligible purchases and computes per-period balances (design §4).
enum BenefitEngine {
    /// `usage`: owner-logged credit use, in minor units per benefit period ID.
    static func evaluate(cards: [Card], transactions: [Transaction], decisions: [String: ReviewDecision], today: Date,
                         usage: [String: Int] = [:]) -> BenefitResult {
        var result = BenefitResult()
        for card in cards {
            let product = Catalog.product(card.productID)
            guard !product.benefits.isEmpty else { continue }
            let txs = transactions.filter { $0.cardID == card.id }
            evaluate(card: card, product: product, txs: txs, decisions: decisions, today: today, usage: usage, into: &result)
        }
        result.periods.sort { ($0.end, $0.rule.name) < ($1.end, $1.rule.name) }
        return result
    }

    private static func periodID(_ rule: BenefitRule, _ card: Card, _ start: Date) -> String {
        "\(rule.id)|\(card.id)|\(Day.key(start))"
    }

    private struct PeriodPurchaseKey: Hashable {
        let periodID: String
        let purchaseID: String
    }

    private struct PurchaseRefund {
        let key: PeriodPurchaseKey
        let purchase: Transaction
        let refund: Transaction
        let amountMinor: Int
    }

    private static func matchRefunds(_ refunds: [Transaction], to purchases: [Transaction], periodID: String) -> [PurchaseRefund] {
        var remaining = Dictionary(uniqueKeysWithValues: purchases.map { ($0.id, $0.amount.minor) })
        var matches: [PurchaseRefund] = []
        for refund in refunds.sorted(by: { ($0.posted, $0.id) < ($1.posted, $1.id) }) {
            let amount = refund.amount.abs.minor
            let candidates = purchases.filter {
                $0.posted <= refund.posted && (remaining[$0.id] ?? 0) >= amount
                    && $0.merchant.caseInsensitiveCompare(refund.merchant) == .orderedSame
            }
            let exact = candidates.filter { $0.amount.minor == amount }
            let purchase = exact.max { ($0.posted, $0.id) < ($1.posted, $1.id) }
                ?? (candidates.count == 1 ? candidates.first : nil)
            guard let purchase else { continue }
            remaining[purchase.id, default: 0] -= amount
            matches.append(PurchaseRefund(key: PeriodPurchaseKey(periodID: periodID, purchaseID: purchase.id),
                                          purchase: purchase, refund: refund, amountMinor: amount))
        }
        return matches
    }

    private static func evaluate(card: Card, product: CardProduct, txs: [Transaction], decisions: [String: ReviewDecision],
                                 today: Date, usage: [String: Int], into result: inout BenefitResult) {
        // 1. Build windows from the start of covered history through the current window.
        var periods: [String: BenefitPeriod] = [:]
        var order: [String] = []
        // Remaining unreimbursed amount keyed per (period, purchase) so overlapping rules on one card never collide.
        var open: [PeriodPurchaseKey: Int] = [:]
        var matchedRefunds: [PurchaseRefund] = []
        // Purchases that received at least a partial allocation in a period (should not also be marked capReached).
        var reimbursed: Set<PeriodPurchaseKey> = []

        let cardRenewal = renewal(for: card, transactions: txs, today: today)
        // Certificates and memberships aren't period balances; they're tracked separately.
        for rule in product.benefits where rule.redemption.tracksPeriods {
            let matchesPurchases = rule.redemption == .statementCredit
            var start = windowStart(rule.period, containing: card.historyStart, renewal: cardRenewal)
            while start <= today {
                let id = periodID(rule, card, start)
                let end = rule.period.end(from: start)
                let inWindow = txs.filter { $0.posted >= start && $0.posted < end && $0.amount.currency == rule.cap.currency }
                // In-app credits are spent inside the merchant's app, so card purchases are not evidence.
                let eligible = matchesPurchases ? inWindow.filter { $0.kind == .purchase && !$0.pending && rule.isEligible($0) } : []
                let pending = matchesPurchases ? inWindow.filter { $0.kind == .purchase && $0.pending && rule.isEligible($0) } : []
                let refunds = matchesPurchases ? inWindow.filter {
                    $0.kind == .refund && !$0.pending && $0.posted <= today && rule.isEligible($0)
                } : []
                periods[id] = BenefitPeriod(id: id, card: card, rule: rule, start: start, end: end,
                                            confirmed: .zero(rule.cap.currency), awaiting: .zero(rule.cap.currency),
                                            allocations: [], eligiblePurchases: eligible, pendingPurchases: pending, refunds: refunds)
                order.append(id)
                for p in eligible { open[PeriodPurchaseKey(periodID: id, purchaseID: p.id)] = p.amount.minor }
                for p in pending {
                    result.evidence[p.id, default: []].append(EvidenceLink(periodID: id, status: .pendingPurchase, note: "Counts once the purchase posts."))
                }
                matchedRefunds += matchRefunds(refunds, to: eligible, periodID: id)
                start = end
            }
        }

        matchedRefunds.sort { ($0.refund.posted, $0.refund.id) < ($1.refund.posted, $1.refund.id) }
        var nextRefund = 0
        var refunded: [PeriodPurchaseKey: Int] = [:]
        func applyRefunds(through date: Date) {
            while nextRefund < matchedRefunds.count && matchedRefunds[nextRefund].refund.posted <= date {
                let match = matchedRefunds[nextRefund]
                nextRefund += 1
                open[match.key] = max(0, (open[match.key] ?? 0) - match.amountMinor)
                refunded[match.key, default: 0] += match.amountMinor
                result.evidence[match.refund.id, default: []].append(EvidenceLink(
                    periodID: match.key.periodID, status: .refunded,
                    note: "Refund for the \(match.purchase.amount.formatted) purchase on \(Day.format(match.purchase.posted))."))
                if refunded[match.key] == match.purchase.amount.minor {
                    result.evidence[match.purchase.id, default: []].append(EvidenceLink(
                        periodID: match.key.periodID, status: .refunded,
                        note: "Fully refunded by \(Day.format(match.refund.posted))."))
                }
            }
        }

        func periodsForCreditDate(_ credit: Transaction, rule: BenefitRule) -> [String] {
            order.filter { id in
                guard let p = periods[id], p.rule.id == rule.id, credit.amount.currency == p.cap.currency else { return false }
                return credit.posted >= p.start && credit.posted < Day.add(rule.creditLagDays, to: p.end)
            }
        }

        func candidates(for credit: Transaction, rule: BenefitRule) -> [String] {
            periodsForCreditDate(credit, rule: rule).filter { id in
                guard let p = periods[id], p.remaining.minor > 0 else { return false }
                return p.eligiblePurchases.contains {
                    $0.posted <= credit.posted && (open[PeriodPurchaseKey(periodID: id, purchaseID: $0.id)] ?? 0) > 0
                }
            }
        }

        func allocate(_ credit: Transaction, to id: String, origin: AllocationOrigin, reason: String, withoutPurchase: Bool = false) {
            guard var p = periods[id] else {
                if origin == .owner {
                    result.evidence[credit.id, default: []].append(EvidenceLink(
                        periodID: "", status: .unmatched,
                        note: "Owner assigned this credit to a benefit period that is no longer available."))
                }
                return
            }
            guard credit.amount.currency == p.cap.currency else { return }
            var budget = min(credit.amount.abs.minor, p.remaining.minor)
            var used: [String] = []
            for purchase in p.eligiblePurchases.filter({ $0.posted <= credit.posted }).sorted(by: { $0.posted < $1.posted }) where budget > 0 {
                let key = PeriodPurchaseKey(periodID: id, purchaseID: purchase.id)
                let take = min(budget, open[key] ?? 0)
                guard take > 0 else { continue }
                open[key, default: 0] -= take
                budget -= take
                used.append(purchase.id)
                reimbursed.insert(key)
            }
            var amount = min(credit.amount.abs.minor, p.remaining.minor) - budget
            // An owner decision may confirm a credit without matched purchase evidence (manual adjustment).
            // The issuer posts a named credit only after a qualifying purchase, even when the feed's merchant
            // text doesn't let us identify it.
            if (origin == .owner || withoutPurchase) && amount == 0 { amount = min(credit.amount.abs.minor, p.remaining.minor) }
            guard amount > 0 else {
                if origin == .owner {
                    result.evidence[credit.id, default: []].append(EvidenceLink(
                        periodID: id, status: .capReached,
                        note: "Owner assigned this credit to \(p.rule.name), which is already used in full for this period."))
                }
                return
            }
            let alloc = Allocation(id: "\(credit.id)>\(id)", creditID: credit.id, purchaseIDs: used,
                                   amount: Money(amount, p.cap.currency), origin: origin, reason: reason)
            p.allocations.append(alloc)
            p.confirmed = p.confirmed + alloc.amount
            periods[id] = p
            let partial = amount < credit.amount.abs.minor ? " Uses \(Money(amount, p.cap.currency).formatted) of this credit." : ""
            result.evidence[credit.id, default: []].append(EvidenceLink(periodID: id, status: .confirmed, note: reason + partial))
            for pid in used {
                result.evidence[pid, default: []].append(EvidenceLink(periodID: id, status: .confirmed, note: "Reimbursed by the \(Day.format(credit.posted)) credit."))
            }
        }

        func review(_ credit: Transaction, reason: String, candidateIDs: [String], cappedIDs: [String] = []) {
            result.reviews.append(ReviewItem(credit: credit, card: card, reason: reason,
                                             candidatePeriodIDs: candidateIDs, cappedPeriodIDs: cappedIDs))
            result.evidence[credit.id, default: []].append(EvidenceLink(periodID: "", status: .needsReview, note: reason))
        }

        func applyCredit(_ credit: Transaction) {
            if let decision = decisions[credit.id] {
                switch decision {
                case .keepUnmatched:
                    result.evidence[credit.id, default: []].append(EvidenceLink(periodID: "", status: .unmatched, note: "Owner kept this credit unmatched."))
                case .assign(let id):
                    allocate(credit, to: id, origin: .owner, reason: "Owner selected this benefit period in review.")
                }
                return
            }
            if let rule = BenefitEngine.namedRule(for: credit, in: product.benefits.filter { $0.redemption == .statementCredit }) {
                let c = candidates(for: credit, rule: rule)
                if c.count == 1 {
                    let p = periods[c[0]]!
                    let late = credit.posted >= p.end
                    let reason = late
                        ? "Issuer credit names \(rule.name). Posted after the window closed; the eligible purchase assigns it to \(Day.monthTitle(p.start))."
                        : "Issuer credit names \(rule.name), with an eligible purchase in this period."
                    allocate(credit, to: c[0], origin: .automatic, reason: reason)
                } else if c.count > 1 {
                    let reason = "Issuer credit names \(rule.name), and several periods have unreimbursed eligible purchases. Confirm which period it belongs to."
                    review(credit, reason: reason, candidateIDs: c)
                } else {
                    let datePeriods = periodsForCreditDate(credit, rule: rule).compactMap { periods[$0] }
                    let available = datePeriods.filter { $0.remaining.minor > 0 }
                    let capped = datePeriods.filter { $0.remaining.isZero }.map(\.id)
                    let postingPeriod = available.first { credit.posted < $0.end }
                    let automaticPeriod = postingPeriod ?? (rule.reviewOverlappingPeriods ? nil : available.last)
                    if datePeriods.isEmpty {
                        review(credit, reason: "The credit names \(rule.name). No tracked period covers this posting date and currency.",
                               candidateIDs: [])
                    } else if available.isEmpty {
                        review(credit, reason: "The credit names \(rule.name). The matching periods have reached their credit limits.",
                               candidateIDs: [], cappedIDs: capped)
                    } else if rule.reviewOverlappingPeriods && available.count > 1 {
                        let reason = "The credit names \(rule.name). It could belong to either period. Check when the qualifying purchase was charged."
                        review(credit, reason: reason, candidateIDs: available.map(\.id), cappedIDs: capped)
                    } else if let automaticPeriod {
                        let reason = "Issuer credit names \(rule.name). The qualifying purchase isn't identifiable in the feed; assigned by posted date."
                        allocate(credit, to: automaticPeriod.id, origin: .automatic, reason: reason, withoutPurchase: true)
                    } else {
                        let reason = "The credit names \(rule.name). An earlier period has room. Check when the qualifying purchase was charged before assigning the credit."
                        review(credit, reason: reason, candidateIDs: available.map(\.id), cappedIDs: capped)
                    }
                }
            } else {
                // Generic issuer description: may be a benefit credit or an unrelated adjustment.
                var c = product.benefits.flatMap { candidates(for: credit, rule: $0) }
                if c.isEmpty {
                    // Allow a manual adjustment against any window that contains the credit date and has room.
                    c = order.filter {
                        guard let p = periods[$0] else { return false }
                        return p.rule.redemption == .statementCredit && p.cap.currency == credit.amount.currency
                            && p.start <= credit.posted && credit.posted < p.end && p.remaining.minor > 0
                    }
                }
                let reason = "The issuer description is generic and could be a benefit credit or an unrelated adjustment."
                review(credit, reason: reason, candidateIDs: c)
            }
        }

        func applyCreditReversal(_ reversal: Transaction) -> Bool {
            guard let rule = BenefitEngine.namedRule(for: reversal, in: product.benefits.filter { $0.redemption == .statementCredit }) else {
                return false
            }
            let eligible = order.compactMap { periods[$0] }.filter {
                $0.rule.id == rule.id && $0.cap.currency == reversal.amount.currency && $0.confirmed.minor >= reversal.amount.minor
            }
            // A recent refund linked to the original purchase can distinguish periods around a reset.
            let recentRefunds = matchedRefunds.prefix(nextRefund).filter {
                Day.days(from: $0.refund.posted, to: reversal.posted) <= rule.creditLagDays
            }
            let refundDates = eligible.compactMap { period -> (periodID: String, date: Date)? in
                let purchaseIDs = Set(period.allocations.flatMap(\.purchaseIDs))
                return recentRefunds.last {
                    $0.key.periodID == period.id && purchaseIDs.contains($0.purchase.id)
                }.map { (period.id, $0.refund.posted) }
            }
            let latest = refundDates.map(\.date).max()
            let latestMatches = refundDates.filter { $0.date == latest }
            let periodID = eligible.count == 1 ? eligible.first?.id : (latestMatches.count == 1 ? latestMatches.first?.periodID : nil)
            guard let periodID, var period = periods[periodID] else { return false }
            period.confirmed = period.confirmed - reversal.amount
            period.creditReversals.append(reversal)
            periods[periodID] = period
            result.evidence[reversal.id, default: []].append(EvidenceLink(
                periodID: periodID, status: .creditReversal,
                note: "Restored \(reversal.amount.formatted) of \(rule.name) to the original period."))
            return true
        }

        // 2. Process posted issuer credits and reversals in date order.
        let benefitTransactions = txs.filter {
            !$0.pending && $0.posted <= today && (($0.kind == .issuerCredit && $0.amount.minor < 0)
                || ($0.kind == .issuerCreditReversal && $0.amount.minor > 0))
        }
        let eventsByDay = Dictionary(grouping: benefitTransactions, by: \.posted)
        for day in eventsByDay.keys.sorted() {
            // A later refund must not erase the evidence available when an issuer credit posted.
            applyRefunds(through: day)
            let events = eventsByDay[day, default: []].sorted { $0.id < $1.id }
            let deferredReversals = events.filter { $0.kind == .issuerCreditReversal && !applyCreditReversal($0) }
            for credit in events where credit.kind == .issuerCredit { applyCredit(credit) }
            for reversal in deferredReversals where !applyCreditReversal(reversal) {
                result.evidence[reversal.id, default: []].append(EvidenceLink(
                    periodID: "", status: .creditReversal, note: "The original benefit period could not be identified from the feed."))
            }
        }

        applyRefunds(through: today)
        // 3. Remaining open purchases become "Awaiting credit" (within lag) or "Not credited".
        for id in order {
            guard var p = periods[id] else { continue }
            // An imported issuer match supersedes owner-logged use for this period.
            if p.usesLoggedUsage {
                p.confirmed = Money(min(p.cap.minor, max(0, usage[id] ?? 0)), p.cap.currency)
            }
            var awaitingMinor = 0
            // Only as much as the cap still allows can arrive; purchases beyond that won't be credited.
            var room = p.remaining.minor
            for purchase in p.eligiblePurchases.sorted(by: { $0.posted < $1.posted }) {
                let key = PeriodPurchaseKey(periodID: id, purchaseID: purchase.id)
                let left = open[key] ?? 0
                guard left > 0 else { continue }
                if room == 0 {
                    // Don't label a purchase "Cap reached" if it was already reimbursed up to the cap.
                    if !reimbursed.contains(key) {
                        result.evidence[purchase.id, default: []].append(EvidenceLink(
                            periodID: id, status: .capReached,
                            note: "\(p.rule.name) is already used in full for this period, so no credit is expected for this purchase."))
                    }
                    continue
                }
                let stillExpected = today < Day.add(p.rule.creditLagDays, to: p.end)
                if stillExpected { awaitingMinor += min(left, room) }
                room -= min(left, room)
                result.evidence[purchase.id, default: []].append(EvidenceLink(
                    periodID: id, status: stillExpected ? .awaitingCredit : .notCredited,
                    note: stillExpected ? "Eligible purchase; issuer credit usually posts within \(p.rule.creditLagDays) days."
                                        : "No credit posted within the expected lag. Check enrollment or eligibility."))
            }
            p.awaiting = Money(min(awaitingMinor, p.remaining.minor), p.cap.currency)
            periods[id] = p
        }

        result.periods.append(contentsOf: order.compactMap { periods[$0] })
    }

    /// Window start for a period. Cardmember-year windows anchor on the renewal month/day (design §5);
    /// with only month precision they start on the 1st of that month; without a renewal date they use the calendar year.
    static func windowStart(_ period: PeriodKind, containing date: Date, renewal: RenewalDate?) -> Date {
        guard period == .cardmemberYear, let renewal else { return period.start(containing: date) }
        let r = Day.ymd(renewal.date)
        let day = renewal.precision == .day ? r.d : 1
        let y = Day.ymd(date).y
        // Clamp e.g. Feb 29 renewals to the last day of the month in non-leap years.
        func anchor(_ year: Int) -> Date {
            let first = Day.make(year, r.m, 1)
            let last = Day.ymd(Day.add(-1, to: Day.addMonths(1, to: first))).d
            return Day.make(year, r.m, min(day, last))
        }
        let thisYear = anchor(y)
        return thisYear <= date ? thisYear : anchor(y - 1)
    }

    // MARK: - Credit descriptors

    static func words(_ s: String) -> Set<String> {
        // "Reimbursement"/"Rebate"/"Cr" are common issuer phrasings for "Credit".
        Set(s.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
            .map { ["REIMBURSEMENT", "REBATE", "CR"].contains($0) ? "CREDIT" : $0 }
            .flatMap { $0 == "HOTELCREDIT" ? ["HOTEL", "CREDIT"] : [$0] })
    }

    /// The benefit a credit's issuer text names. A rule matches when every word of its descriptor — or of the
    /// benefit's own name plus "CREDIT" — appears in the text, e.g. "AMEX Hilton Honors Aspire Resort Credit" matches
    /// HILTON RESORT CREDIT. The most specific match wins; a tie between different benefits is not a match.
    static func namedRule(for credit: Transaction, in rules: [BenefitRule]) -> BenefitRule? {
        let text = words(credit.originalDescription)
        guard text.contains("CREDIT") else { return nil }
        var best: (rule: BenefitRule, score: Int)?
        var tie = false
        for rule in rules {
            let patterns = [words(rule.creditDescriptor), words(rule.name).union(["CREDIT"])]
            let score = patterns.filter { $0.count >= 2 && $0.isSubset(of: text) }.map(\.count).max() ?? 0
            guard score > 0 else { continue }
            if score > (best?.score ?? 0) { best = (rule, score); tie = false }
            else if score == best?.score && best?.rule.id != rule.id { tie = true }
        }
        return tie ? nil : best?.rule
    }

    // MARK: - Renewal and fees (design §5, RewardRadar "effective annual fee")

    static func renewal(for card: Card, transactions: [Transaction], today: Date = Day.today) -> RenewalDate? {
        let floor = Day.startOfMonth(today)
        if let r = card.renewal {
            var next = r.date
            while next < floor { next = Day.addMonths(12, to: next) }
            return RenewalDate(date: next, precision: r.precision, source: r.source)
        }
        if let fee = transactions
            .filter({ $0.cardID == card.id && $0.kind == .fee && $0.amount.minor > 0 && PlaidMapping.isAnnualFee($0.originalDescription.uppercased()) })
            .max(by: { $0.posted < $1.posted }) {
            // The fee posts on the renewal billing date; the next one follows a year later.
            var next = Day.addMonths(12, to: fee.posted)
            while next < floor { next = Day.addMonths(12, to: next) }
            return RenewalDate(date: next, precision: .day, source: .inferredFromFee)
        }
        // Without a posted fee or entered date, a confirmed open date gives the account anniversary (never opening day itself).
        guard card.openDateStatus == .confirmed else { return nil }
        var next = Day.addMonths(12, to: card.openedOn)
        while next < floor { next = Day.addMonths(12, to: next) }
        return RenewalDate(date: next, precision: .day, source: .openAnniversary)
    }

    /// Confirmed credits redeemed in `(since, today]`, using posting dates or owner-logged usage dates.
    static func creditsRedeemed(card: Card, periods: [BenefitPeriod], transactions: [Transaction],
                                usageLogs: [UsageLog] = [], since: Date, today: Date = Day.today) -> Money {
        let currency = Catalog.product(card.productID).annualFee.currency
        let postedByID = Dictionary(uniqueKeysWithValues: transactions.filter { $0.cardID == card.id }.map { ($0.id, $0.posted) })
        let usageByPeriod = Dictionary(grouping: usageLogs.filter { $0.usedOn > since && $0.usedOn <= today && $0.amount.currency == currency },
                                       by: \.periodID)
        var total = 0
        for p in periods where p.card.id == card.id && p.cap.currency == currency {
            if p.usesLoggedUsage {
                let logged = (usageByPeriod[p.id] ?? []).reduce(0) { total, log in
                    // Older in-app logs can have dates outside their period. Keep their dated fee accounting.
                    guard p.rule.redemption == .appCredit || (p.start <= log.usedOn && log.usedOn < p.end) else { return total }
                    return total + log.amount.minor
                }
                total += min(p.cap.minor, logged)
            } else {
                for a in p.allocations where a.amount.currency == currency {
                    if let d = postedByID[a.creditID], d > since && d <= today {
                        total += a.amount.minor
                    }
                }
                for reversal in p.creditReversals where reversal.posted > since && reversal.posted <= today {
                    total -= reversal.amount.minor
                }
            }
        }
        return Money(total, currency)
    }
}
