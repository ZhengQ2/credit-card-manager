import Foundation

/// How the owner answered "Is <history start> when you opened this card?"
enum OpenDateStatus: String {
    /// Not asked yet; the date is the start of covered history.
    case estimated
    /// The owner confirmed (or entered) the open date.
    case confirmed
    /// The owner said the card is older than the covered history and didn't give a date. Excluded from 5/24.
    case older
}

/// A sign-up offer on a newly opened card.
struct WelcomeOffer: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        /// Spend X within N months → earn a fixed number of points or miles.
        case spendBonus
        /// Spend X within N months → statement credit (cash).
        case statementCredit
        /// Extra earn rate on categories for the first N months (e.g. +5× groceries for 6 months, up to a cap).
        case bonusEarn
        /// First-year annual fee waived.
        case feeWaiver

        var id: String { rawValue }

        var title: String {
            switch self {
            case .spendBonus: "Bonus points"
            case .statementCredit: "Statement credit"
            case .bonusEarn: "Bonus earn rate"
            case .feeWaiver: "Annual fee waiver"
            }
        }

        var symbol: String {
            switch self {
            case .spendBonus: "star.circle"
            case .statementCredit: "dollarsign.circle"
            case .bonusEarn: "multiply.circle"
            case .feeWaiver: "checkmark.seal"
            }
        }

        var needsSpend: Bool { self == .spendBonus || self == .statementCredit }
    }

    let id: String
    let cardID: String
    var kind: Kind
    var currency: CurrencyCode = .usd
    /// Usually the card's open date.
    var start: Date
    var months: Int
    var minSpend: Money?
    /// Points/miles for `spendBonus`.
    var points: Double?
    /// Cash for `statementCredit`.
    var cash: Money?
    /// Extra multiplier (on top of the card's normal rate) for `bonusEarn`.
    var extraMultiplier: Double?
    var categories: Set<RewardCategory>
    /// Bonus-earn spend cap for the whole window.
    var spendCap: Money?
    var notes: String
    /// Owner override once the issuer has posted the bonus.
    var markedEarned: Bool

    /// Exclusive end: the last eligible day is the day before.
    var end: Date { Day.addMonths(months, to: start) }
    var lastDay: Date { Day.add(-1, to: end) }
}

struct WelcomeOfferProgress: Hashable {
    enum State: String { case inProgress = "In progress", met = "Spend met", earned = "Earned", missed = "Missed", active = "Active", ended = "Ended" }

    let offer: WelcomeOffer
    /// Net eligible spend inside the window (purchases − refunds).
    let spend: Money
    let remaining: Money?
    let fraction: Double
    let state: State
    /// For bonusEarn: extra points earned so far.
    let extraPoints: Double?
    let daysLeft: Int

    var reward: String {
        switch offer.kind {
        case .spendBonus:
            return "\((offer.points ?? 0).formatted(.number.precision(.fractionLength(0)))) points"
        case .statementCredit:
            return offer.cash?.formatted ?? "Credit"
        case .bonusEarn:
            let cats = offer.categories.isEmpty ? "all purchases" : offer.categories.map(\.title).sorted().joined(separator: ", ")
            return "+\((offer.extraMultiplier ?? 0).formatted())× on \(cats)"
        case .feeWaiver:
            return "First-year fee waived"
        }
    }
}

enum WelcomeOfferEngine {
    static func progress(_ offer: WelcomeOffer, transactions: [Transaction], today: Date,
                         cardCurrency: CurrencyCode? = nil) -> WelcomeOfferProgress {
        let currency = cardCurrency ?? offer.minSpend?.currency ?? offer.spendCap?.currency ?? offer.cash?.currency ?? offer.currency
        let inWindow = transactions.filter {
            $0.cardID == offer.cardID && !$0.pending && $0.posted >= offer.start && $0.posted < offer.end
            && ($0.kind == .purchase || $0.kind == .refund) && $0.amount.currency == currency
        }
        let eligible = offer.kind == .bonusEarn && !offer.categories.isEmpty
            ? inWindow.filter { offer.categories.contains($0.category) } : inWindow
        let spend = Money(max(0, eligible.reduce(0) { $0 + $1.amount.minor }), currency)
        let daysLeft = max(0, Day.days(from: today, to: offer.lastDay))
        let over = today >= offer.end

        switch offer.kind {
        case .spendBonus, .statementCredit:
            let target = offer.minSpend ?? .zero(currency)
            let remaining = Money(max(0, target.minor - spend.minor), currency)
            let fraction = target.minor > 0 ? min(1, max(0, Double(spend.minor) / Double(target.minor))) : 0
            let met = target.minor > 0 && remaining.isZero
            let state: WelcomeOfferProgress.State =
                offer.markedEarned ? .earned : met ? .met : over ? .missed : .inProgress
            return WelcomeOfferProgress(offer: offer, spend: spend, remaining: remaining, fraction: fraction, state: state,
                                        extraPoints: nil, daysLeft: daysLeft)
        case .bonusEarn:
            let capped = offer.spendCap.map { Money(min($0.minor, spend.minor), currency) } ?? spend
            let extra = Double(capped.minor) / 100 * max(0, offer.extraMultiplier ?? 0)
            let timeFraction = Double(Day.days(from: offer.start, to: today)) / Double(max(1, Day.days(from: offer.start, to: offer.end)))
            let fraction = min(1, max(0, offer.spendCap.map { $0.minor > 0 ? Double(spend.minor) / Double($0.minor) : timeFraction } ?? timeFraction))
            return WelcomeOfferProgress(offer: offer, spend: spend,
                                        remaining: offer.spendCap.map { Money(max(0, $0.minor - spend.minor), currency) },
                                        fraction: fraction, state: over ? .ended : .active, extraPoints: extra, daysLeft: daysLeft)
        case .feeWaiver:
            let fraction = min(1, max(0, Double(Day.days(from: offer.start, to: today)) / Double(max(1, Day.days(from: offer.start, to: offer.end)))))
            return WelcomeOfferProgress(offer: offer, spend: spend, remaining: nil, fraction: fraction,
                                        state: over ? .ended : .active, extraPoints: nil, daysLeft: daysLeft)
        }
    }
}
