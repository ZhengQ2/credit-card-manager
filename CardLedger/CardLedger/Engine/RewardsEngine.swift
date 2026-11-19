import Foundation

/// Owner-editable valuation assumptions. Nothing is converted with an unstated rate (design §9).
struct Assumptions: Hashable, Codable {
    var centsPerPoint: [String: Double] = Dictionary(uniqueKeysWithValues: Catalog.programs.map { ($0.id, $0.defaultCentsPerPoint) })
    /// CAD per 1 USD.
    var cadPerUSD: Double = 1.38

    func convert(_ minor: Double, from: CurrencyCode, to: CurrencyCode) -> Double {
        if from == to { return minor }
        return from == .usd ? minor * cadPerUSD : minor / cadPerUSD
    }
}

struct EarnQuote: Hashable {
    let card: Card
    let product: CardProduct
    let multiplier: Double
    let bonusMultiplier: Double
    let points: Double
    /// Reward value minus foreign-transaction cost, in minor units of the purchase currency.
    let netValueMinor: Double
    let fxCostMinor: Double
    let uncertain: Bool
    let capNote: String?
    let ruleNote: String?
    let explanation: String
}

/// Earn-rate lookup, cap tracking, and historical replay (design §9 + RewardRadar "best card per category").
struct RewardsEngine {
    let cards: [Card]
    let assumptions: Assumptions
    var renewals: [String: RenewalDate] = [:]

    typealias CapUsage = [String: Int]

    private func capKey(_ card: Card, _ ruleIndex: Int, period: PeriodKind, date: Date) -> String {
        let renewal = renewals[card.id] ?? card.renewal ?? RenewalDate(date: card.openedOn, precision: .month, source: .owner)
        let start = BenefitEngine.windowStart(period, containing: date, renewal: renewal)
        return "\(card.id)|\(ruleIndex)|\(Day.key(start))"
    }

    /// The matching rule with the best effective rate. Rules whose bonus can't be confirmed from the feed
    /// (booking channel, rotating or chosen categories, unknown merchant) count at the base rate, so a certain
    /// 3× beats an uncertain 5×. Ties prefer the certain rule.
    private func matchingRule(_ product: CardProduct, category: RewardCategory, merchant: String?) -> (Int, EarnRule)? {
        let candidates = product.earnRules.enumerated().filter { _, rule in
            guard rule.categories.contains(category) else { return false }
            guard !rule.merchantKeywords.isEmpty else { return true }
            guard let merchant else { return true }
            return rule.merchantKeywords.contains { merchant.lowercased().contains($0) }
        }
        func uncertain(_ r: EarnRule) -> Bool { r.channelRestricted || (merchant == nil && !r.merchantKeywords.isEmpty) }
        func effective(_ r: EarnRule) -> Double { uncertain(r) ? product.baseMultiplier : r.multiplier }
        return candidates.max { a, b in
            let ea = effective(a.element), eb = effective(b.element)
            if ea != eb { return ea < eb }
            if uncertain(a.element) != uncertain(b.element) { return uncertain(a.element) } // certain wins ties
            return a.element.multiplier < b.element.multiplier
        }.map { ($0.offset, $0.element) }
    }

    /// Quote one purchase on one card. `merchant == nil` means a category-level question ("which card for dining?").
    func quote(card: Card, amount: Money, category: RewardCategory, merchant: String?, date: Date,
               usage: CapUsage, conservative: Bool = true) -> EarnQuote {
        let product = Catalog.product(card.productID)
        let program = Catalog.program(product.programID)
        let cpp = assumptions.centsPerPoint[program.id] ?? program.defaultCentsPerPoint
        let amt = Double(amount.minor) // minor units of purchase currency
        let spendInCardCurrency = assumptions.convert(amt, from: amount.currency, to: product.market)

        var points = spendInCardCurrency / 100 * product.baseMultiplier
        var multiplier = product.baseMultiplier
        var bonus = product.baseMultiplier
        var uncertain = false
        var capNote: String?
        var ruleNote: String?

        if let (index, rule) = matchingRule(product, category: category, merchant: merchant) {
            ruleNote = rule.note
            bonus = rule.multiplier
            let merchantUnknown = merchant == nil && !rule.merchantKeywords.isEmpty
            if rule.channelRestricted || merchantUnknown {
                uncertain = true
                if !conservative { multiplier = rule.multiplier; points = spendInCardCurrency / 100 * rule.multiplier }
            } else if let cap = rule.spendCap, let per = rule.capPeriod {
                let key = capKey(card, index, period: per, date: date)
                let used = max(0, usage[key] ?? 0)
                if spendInCardCurrency >= 0 {
                    let left = max(0, cap.minor - used)
                    let bonusSpend = min(spendInCardCurrency, Double(left))
                    points = bonusSpend / 100 * rule.multiplier + (spendInCardCurrency - bonusSpend) / 100 * product.baseMultiplier
                    multiplier = spendInCardCurrency > 0 ? points / (spendInCardCurrency / 100) : rule.multiplier
                    capNote = "\(Money(left, cap.currency).short) of \(cap.short) bonus spend left this \(per == .monthly ? "month" : "period")"
                } else {
                    // Refund: reverse over-cap base-rate spend first, then bonus-rate spend.
                    let refund = -spendInCardCurrency
                    let overCap = Double(max(0, used - cap.minor))
                    let baseRefund = min(refund, overCap)
                    let bonusRefund = refund - baseRefund
                    points = -(bonusRefund / 100 * rule.multiplier + baseRefund / 100 * product.baseMultiplier)
                    multiplier = refund > 0 ? (-points) / (refund / 100) : rule.multiplier
                }
            } else {
                multiplier = rule.multiplier
                points = spendInCardCurrency / 100 * rule.multiplier
            }
        }

        let valueInProgramCurrency = points * cpp // minor units of program currency
        let value = assumptions.convert(valueInProgramCurrency, from: program.currency, to: amount.currency)
        let fx = amount.currency == product.market ? 0 : amt * product.foreignTransactionFee
        let net = value - fx

        var parts = ["\(multiplier.formatted(.number.precision(.fractionLength(0...2))))× \(program.unit) at \(cpp.formatted(.number.precision(.fractionLength(0...2))))¢"]
        if amount.currency != product.market {
            parts.append("FX \(assumptions.cadPerUSD.formatted()) CAD/USD")
            if fx > 0 { parts.append("\((product.foreignTransactionFee * 100).formatted())% FX fee") }
        }
        if uncertain { parts.append(conservative ? "bonus not assumed" : "bonus assumed") }

        return EarnQuote(card: card, product: product, multiplier: multiplier, bonusMultiplier: bonus, points: points,
                         netValueMinor: net, fxCostMinor: fx, uncertain: uncertain, capNote: capNote, ruleNote: ruleNote,
                         explanation: parts.joined(separator: " · "))
    }

    /// Bonus-cap usage from the actual ledger (posted purchases minus refunds).
    func capUsage(from transactions: [Transaction], through date: Date) -> CapUsage {
        var usage: CapUsage = [:]
        for t in transactions.sorted(by: { $0.posted < $1.posted }) where !t.pending && t.posted <= date && (t.kind == .purchase || t.kind == .refund) {
            guard let card = cards.first(where: { $0.id == t.cardID }) else { continue }
            record(t, on: card, into: &usage)
        }
        return usage
    }

    func record(_ t: Transaction, on card: Card, into usage: inout CapUsage) {
        let product = Catalog.product(card.productID)
        guard let (index, rule) = matchingRule(product, category: t.category, merchant: t.merchant),
              !rule.channelRestricted, rule.spendCap != nil, let per = rule.capPeriod else { return }
        let key = capKey(card, index, period: per, date: t.posted)
        let spend = Int(assumptions.convert(Double(t.amount.minor), from: t.amount.currency, to: product.market).rounded())
        usage[key] = max(0, (usage[key] ?? 0) + spend)
    }

    // MARK: - Ranking

    func rank(category: RewardCategory, currency: CurrencyCode, amount: Money, transactions: [Transaction], today: Date) -> [EarnQuote] {
        let usage = capUsage(from: transactions, through: today)
        return rank(category: category, currency: currency, amount: amount, usage: usage, today: today)
    }

    func rank(category: RewardCategory, currency: CurrencyCode, amount: Money, usage: CapUsage, today: Date) -> [EarnQuote] {
        cards.map { quote(card: $0, amount: amount, category: category, merchant: nil, date: today, usage: usage) }
            .sorted { $0.netValueMinor > $1.netValueMinor }
    }

    // MARK: - Replay (design §9)

    struct ReplayLine: Identifiable, Hashable {
        var id: String { transaction.id }
        let transaction: Transaction
        let actual: EarnQuote
        let alternative: EarnQuote
    }

    struct ReplayResult {
        var lines: [ReplayLine] = []
        var notes: [(Transaction, String)] = []
        var actualTotal: Double = 0
        var alternativeTotal: Double = 0
        var byCardActual: [String: Double] = [:]
        var byCardAlternative: [String: Double] = [:]
        var currency: CurrencyCode
        var delta: Double { alternativeTotal - actualTotal }
    }

    /// Replays purchases in date order: actual card vs. best held card at that moment, with caps applied consistently.
    /// Pass `allTransactions` to seed cap usage with earlier/other-category posted spend in the same cap windows.
    func replay(_ transactions: [Transaction], allTransactions: [Transaction]? = nil, currency: CurrencyCode) -> ReplayResult {
        var result = ReplayResult(currency: currency)
        guard !cards.isEmpty else { return result }
        let sorted = transactions.filter { $0.amount.currency == currency && !$0.pending && ($0.kind == .purchase || $0.kind == .refund) }
            .sorted { $0.posted < $1.posted }
        guard let lastDate = sorted.last?.posted else { return result }

        // Interleave non-replayed posted spend (earlier in the cap period, other categories, or other currencies)
        // chronologically so annual/monthly caps reflect real usage on the actual and alternative ledgers.
        let replayedIDs = Set(sorted.map(\.id))
        let background = (allTransactions ?? [])
            .filter { !$0.pending && !replayedIDs.contains($0.id) && $0.posted <= lastDate && ($0.kind == .purchase || $0.kind == .refund) }
            .sorted { $0.posted < $1.posted }
        var bgIndex = 0
        var actualUsage: CapUsage = [:]
        var altUsage: CapUsage = [:]
        var altCardFor: [String: String] = [:] // merchant -> card used in alternative, so refunds follow purchases

        for t in sorted {
            while bgIndex < background.count && background[bgIndex].posted <= t.posted {
                let bg = background[bgIndex]
                bgIndex += 1
                if let bgCard = cards.first(where: { $0.id == bg.cardID }) {
                    record(bg, on: bgCard, into: &actualUsage)
                    record(bg, on: bgCard, into: &altUsage)
                }
            }
            guard let actualCard = cards.first(where: { $0.id == t.cardID }) else { continue }

            if t.kind == .refund {
                let a = quote(card: actualCard, amount: t.amount, category: t.category, merchant: t.merchant, date: t.posted, usage: actualUsage)
                let altCard = cards.first { $0.id == altCardFor[t.merchant] } ?? actualCard
                let b = quote(card: altCard, amount: t.amount, category: t.category, merchant: t.merchant, date: t.posted, usage: altUsage)
                result.lines.append(ReplayLine(transaction: t, actual: a, alternative: b))
                accumulate(a, b, into: &result)
                record(t, on: actualCard, into: &actualUsage)
                record(t, on: altCard, into: &altUsage)
                continue
            }

            let a = quote(card: actualCard, amount: t.amount, category: t.category, merchant: t.merchant, date: t.posted, usage: actualUsage)
            let options = cards.map { quote(card: $0, amount: t.amount, category: t.category, merchant: t.merchant, date: t.posted, usage: altUsage) }
            guard let best = options.max(by: { $0.netValueMinor < $1.netValueMinor }) else { continue }
            if a.uncertain || best.uncertain {
                result.notes.append((t, "Bonus depends on a booking channel the feed cannot see; counted at the base rate."))
            }
            result.lines.append(ReplayLine(transaction: t, actual: a, alternative: best))
            accumulate(a, best, into: &result)
            altCardFor[t.merchant] = best.card.id
            record(t, on: actualCard, into: &actualUsage)
            record(t, on: best.card, into: &altUsage)
        }
        return result
    }

    private func accumulate(_ a: EarnQuote, _ b: EarnQuote, into r: inout ReplayResult) {
        r.actualTotal += a.netValueMinor
        r.alternativeTotal += b.netValueMinor
        r.byCardActual[a.card.id, default: 0] += a.netValueMinor
        r.byCardAlternative[b.card.id, default: 0] += b.netValueMinor
    }
}
