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

    var cap: Money { rule.cap(for: start) }
    var remaining: Money { Money(max(0, min(cap.minor, cap.minor - confirmed.minor)), cap.currency) }
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
}

struct BenefitResult {
    var periods: [BenefitPeriod] = []
    var reviews: [ReviewItem] = []
    var evidence: [String: [EvidenceLink]] = [:]

    func period(_ id: String) -> BenefitPeriod? { periods.first { $0.id == id } }
}

/// Matches issuer credits to eligible purchases and computes per-period balances (design §4).
enum BenefitEngine {
    /// `usage`: owner-logged use of in-app credits, in minor units per benefit period ID.
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

    private static func evaluate(card: Card, product: CardProduct, txs: [Transaction], decisions: [String: ReviewDecision],
                                 today: Date, usage: [String: Int], into result: inout BenefitResult) {
        // 1. Build windows from the start of covered history through the current window.
        var periods: [String: BenefitPeriod] = [:]
        var order: [String] = []
        // Remaining unreimbursed amount per purchase ID.
        var open: [String: Int] = [:]

        let cardRenewal = renewal(for: card, transactions: txs)
        // Certificates and memberships aren't period balances; they're tracked separately.
        for rule in product.benefits where rule.redemption.tracksPeriods {
            let matchesPurchases = rule.redemption == .statementCredit
            var start = windowStart(rule.period, containing: card.historyStart, renewal: cardRenewal)
            while start <= today {
                let id = periodID(rule, card, start)
                let end = rule.period.end(from: start)
                let inWindow = txs.filter { $0.posted >= start && $0.posted < end }
                // In-app credits are spent inside the merchant's app, so card purchases are not evidence.
                let eligible = matchesPurchases ? inWindow.filter { $0.kind == .purchase && !$0.pending && rule.isEligible($0) } : []
                let pending = matchesPurchases ? inWindow.filter { $0.kind == .purchase && $0.pending && rule.isEligible($0) } : []
                let refunds = matchesPurchases ? inWindow.filter { $0.kind == .refund && rule.isEligible($0) } : []
                periods[id] = BenefitPeriod(id: id, card: card, rule: rule, start: start, end: end,
                                            confirmed: .zero(rule.cap.currency), awaiting: .zero(rule.cap.currency),
                                            allocations: [], eligiblePurchases: eligible, pendingPurchases: pending, refunds: refunds)
                order.append(id)
                for p in eligible { open[p.id] = p.amount.minor }
                for p in pending {
                    result.evidence[p.id, default: []].append(EvidenceLink(periodID: id, status: .pendingPurchase, note: "Counts once the purchase posts."))
                }
                // Refunds reduce eligible net purchases (same merchant first).
                for r in refunds {
                    var left = r.amount.abs.minor
                    for p in eligible.sorted(by: { ($0.merchant == r.merchant ? 0 : 1, $0.posted) < ($1.merchant == r.merchant ? 0 : 1, $1.posted) }) where left > 0 {
                        let take = min(left, open[p.id] ?? 0)
                        open[p.id, default: 0] -= take
                        left -= take
                    }
                }
                start = end
            }
        }

        func candidates(for credit: Transaction, rule: BenefitRule) -> [String] {
            order.filter { id in
                guard let p = periods[id], p.rule.id == rule.id else { return false }
                let inOrLag = credit.posted >= p.start && credit.posted < Day.add(rule.creditLagDays, to: p.end)
                let hasOpen = p.eligiblePurchases.contains { $0.posted <= credit.posted && (open[$0.id] ?? 0) > 0 }
                return inOrLag && hasOpen && p.remaining.minor > 0
            }
        }

        func allocate(_ credit: Transaction, to id: String, origin: AllocationOrigin, reason: String, withoutPurchase: Bool = false) {
            guard var p = periods[id] else { return }
            var budget = min(credit.amount.abs.minor, p.remaining.minor)
            var used: [String] = []
            for purchase in p.eligiblePurchases.sorted(by: { $0.posted < $1.posted }) where budget > 0 {
                let take = min(budget, open[purchase.id] ?? 0)
                guard take > 0 else { continue }
                open[purchase.id, default: 0] -= take
                budget -= take
                used.append(purchase.id)
            }
            var amount = min(credit.amount.abs.minor, p.remaining.minor) - budget
            // An owner decision may confirm a credit without matched purchase evidence (manual adjustment).
            // The issuer posts a named credit only after a qualifying purchase, even when the feed's merchant
            // text doesn't let us identify it.
            if (origin == .owner || withoutPurchase) && amount == 0 { amount = min(credit.amount.abs.minor, p.remaining.minor) }
            guard amount > 0 else { return }
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

        /// The period containing the posted date if it has room; otherwise the previous period still within the credit lag.
        func periodByPostedDate(_ credit: Transaction, rule: BenefitRule, among preferred: [String]) -> String? {
            let ofRule = order.filter { periods[$0]!.rule.id == rule.id && periods[$0]!.remaining.minor > 0 }
            if let containing = ofRule.first(where: { credit.posted >= periods[$0]!.start && credit.posted < periods[$0]!.end }) {
                return containing
            }
            return ofRule.last { credit.posted >= periods[$0]!.end && credit.posted < Day.add(rule.creditLagDays, to: periods[$0]!.end) }
        }

        // 2. Process issuer credits in date order.
        let credits = txs.filter { $0.kind == .issuerCredit && !$0.pending }.sorted { $0.posted < $1.posted }
        for credit in credits {
            if let decision = decisions[credit.id] {
                switch decision {
                case .keepUnmatched:
                    result.evidence[credit.id, default: []].append(EvidenceLink(periodID: "", status: .unmatched, note: "Owner kept this credit unmatched."))
                case .assign(let id):
                    allocate(credit, to: id, origin: .owner, reason: "Owner selected this benefit period in review.")
                }
                continue
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
                } else if let byDate = periodByPostedDate(credit, rule: rule, among: c) {
                    let reason = c.count > 1
                        ? "Issuer credit names \(rule.name). Several periods had eligible purchases; assigned by posted date."
                        : "Issuer credit names \(rule.name). The qualifying purchase isn't identifiable in the feed; assigned by posted date."
                    allocate(credit, to: byDate, origin: .automatic, reason: reason, withoutPurchase: true)
                } else {
                    let reason = "The credit names \(rule.name), but every eligible period is already used up."
                    let all = order.filter { periods[$0]!.rule.id == rule.id && credit.posted >= periods[$0]!.start && credit.posted < Day.add(rule.creditLagDays, to: periods[$0]!.end) }
                    result.reviews.append(ReviewItem(credit: credit, card: card, reason: reason, candidatePeriodIDs: all))
                    result.evidence[credit.id, default: []].append(EvidenceLink(periodID: "", status: .needsReview, note: reason))
                }
            } else {
                // Generic issuer description: may be a benefit credit or an unrelated adjustment.
                var c = product.benefits.flatMap { candidates(for: credit, rule: $0) }
                if c.isEmpty {
                    // Allow a manual adjustment against any window that contains the credit date.
                    c = order.filter { periods[$0]!.rule.redemption == .statementCredit && periods[$0]!.start <= credit.posted
                        && credit.posted < periods[$0]!.end && periods[$0]!.remaining.minor > 0 }
                }
                let reason = "The issuer description is generic and could be a benefit credit or an unrelated adjustment."
                result.reviews.append(ReviewItem(credit: credit, card: card, reason: reason, candidatePeriodIDs: c))
                result.evidence[credit.id, default: []].append(EvidenceLink(periodID: "", status: .needsReview, note: reason))
            }
        }

        // 3. Remaining open purchases become "Awaiting credit" (within lag) or "Not credited".
        for id in order {
            guard var p = periods[id] else { continue }
            var awaitingMinor = 0
            // Only as much as the cap still allows can arrive; purchases beyond that won't be credited.
            var room = p.remaining.minor
            for purchase in p.eligiblePurchases.sorted(by: { $0.posted < $1.posted }) {
                let left = open[purchase.id] ?? 0
                guard left > 0 else { continue }
                if room == 0 {
                    result.evidence[purchase.id, default: []].append(EvidenceLink(
                        periodID: id, status: .capReached,
                        note: "\(p.rule.name) is already used in full for this period, so no credit is expected for this purchase."))
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
            if p.rule.redemption == .appCredit {
                p.confirmed = Money(min(p.cap.minor, usage[id] ?? 0), p.cap.currency)
            }
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
        // "Reimbursement"/"Rebate" are how some issuers say "Credit".
        Set(s.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
            .map { ["REIMBURSEMENT", "REBATE"].contains($0) ? "CREDIT" : $0 })
    }

    /// The benefit a credit's issuer text names. A rule matches when every word of its descriptor — or of the
    /// benefit's own name plus "CREDIT" — appears in the text, e.g. "AMEX Hilton Honors Aspire Resort Credit" matches
    /// HILTON RESORT CREDIT. The most specific match wins; a tie between different benefits is not a match.
    static func namedRule(for credit: Transaction, in rules: [BenefitRule]) -> BenefitRule? {
        let text = words(credit.originalDescription)
        guard text.contains("CREDIT") || text.contains("CR") else { return nil }
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

    static func renewal(for card: Card, transactions: [Transaction]) -> RenewalDate? {
        if let r = card.renewal { return r }
        let fee = transactions
            .filter { $0.cardID == card.id && $0.kind == .fee && PlaidMapping.isAnnualFee($0.originalDescription.uppercased()) }
            .max { $0.posted < $1.posted }
        guard let fee else { return nil }
        // The fee posts on the renewal billing date; the next one follows a year later.
        var next = Day.addMonths(12, to: fee.posted)
        while next < Day.startOfMonth(Day.today) { next = Day.addMonths(12, to: next) }
        return RenewalDate(date: next, precision: .day, source: .inferredFromFee)
    }

    static func creditsRedeemed(card: Card, periods: [BenefitPeriod], since: Date) -> Money {
        let currency = Catalog.product(card.productID).annualFee.currency
        return periods.filter { $0.card.id == card.id && $0.end > since }
            .reduce(Money.zero(currency)) { $0 + ($1.confirmed.currency == currency ? $1.confirmed : .zero(currency)) }
    }
}
