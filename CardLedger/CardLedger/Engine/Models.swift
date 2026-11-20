import Foundation

// MARK: - Money

enum CurrencyCode: String, CaseIterable, Identifiable, Hashable, Codable {
    case usd = "USD"
    case cad = "CAD"
    var id: String { rawValue }
}

/// Signed integer minor units plus an explicit currency (design §8).
struct Money: Hashable, Comparable, Codable {
    var minor: Int
    var currency: CurrencyCode

    init(_ minor: Int, _ currency: CurrencyCode) {
        self.minor = minor
        self.currency = currency
    }

    static func dollars(_ value: Double, _ currency: CurrencyCode) -> Money {
        Money(Int((value * 100).rounded()), currency)
    }

    static func zero(_ currency: CurrencyCode) -> Money { Money(0, currency) }

    var isZero: Bool { minor == 0 }
    var abs: Money { Money(Swift.abs(minor), currency) }
    var decimal: Double { Double(minor) / 100 }

    static func + (l: Money, r: Money) -> Money { precondition(l.currency == r.currency); return Money(l.minor + r.minor, l.currency) }
    static func - (l: Money, r: Money) -> Money { precondition(l.currency == r.currency); return Money(l.minor - r.minor, l.currency) }
    static prefix func - (m: Money) -> Money { Money(-m.minor, m.currency) }
    static func < (l: Money, r: Money) -> Bool { precondition(l.currency == r.currency); return l.minor < r.minor }
    static func min(_ a: Money, _ b: Money) -> Money { precondition(a.currency == b.currency); return a.minor <= b.minor ? a : b }
    static func max(_ a: Money, _ b: Money) -> Money { precondition(a.currency == b.currency); return a.minor >= b.minor ? a : b }

    /// Explicit currency code, e.g. "USD 25.00" — the wallet spans CAD and USD.
    var formatted: String {
        let value = Double(Swift.abs(minor)) / 100
        let number = value.formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
        return "\(minor < 0 ? "−" : "")\(currency.rawValue) \(number)"
    }

    var short: String {
        let value = Double(Swift.abs(minor)) / 100
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(minor < 0 ? "−" : "")\(currency.rawValue) \(number)"
    }
}

// MARK: - Date-only values

/// Date-only values evaluated on a fixed calendar, independent of the phone's time zone (design §5).
enum Day {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func make(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    static var today: Date {
        let local = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return make(local.year!, local.month!, local.day!)
    }

    static func add(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    static func addMonths(_ months: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: months, to: date)!
    }

    static func days(from a: Date, to b: Date) -> Int {
        calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    static func ymd(_ date: Date) -> (y: Int, m: Int, d: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    static func startOfMonth(_ date: Date) -> Date {
        let p = ymd(date)
        return make(p.y, p.m, 1)
    }

    static func format(_ date: Date, _ style: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()) -> String {
        var s = style
        s.timeZone = calendar.timeZone
        return date.formatted(s)
    }

    static func key(_ date: Date) -> String {
        let p = ymd(date)
        return String(format: "%04d-%02d-%02d", p.y, p.m, p.d)
    }

    static func monthTitle(_ date: Date) -> String {
        format(date, .dateTime.month(.wide).year())
    }

    /// Converts a UTC date-only value to local noon on the same calendar date for `DatePicker` bindings,
    /// preventing off-by-one-day shifts in Western Hemisphere timezones and across DST transitions.
    static func toLocal(_ utcDay: Date) -> Date {
        let p = ymd(utcDay)
        return Calendar.current.date(from: DateComponents(year: p.y, month: p.m, day: p.d, hour: 12)) ?? utcDay
    }

    /// Converts a local-timezone `Date` (e.g. from `DatePicker`) back to a UTC date-only value.
    static func fromLocal(_ localDate: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: localDate)
        return make(c.year!, c.month!, c.day!)
    }
}

// MARK: - Catalog

enum RewardCategory: String, CaseIterable, Identifiable, Hashable, Codable {
    case dining, groceries, gas, evCharging
    case flights, hotels, carRental, travel, transit
    case streaming, drugstore, entertainment
    case wholesale, homeImprovement, shopping
    case telecom, utilities, fitness, healthcare, auto, office, insurance
    case other

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case everyday = "Everyday"
        case travel = "Travel & transit"
        case shoppingAndHome = "Shopping & home"
        case billsAndServices = "Bills & services"
        case healthAndAuto = "Health, fitness & auto"
        case other = "Other"

        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .dining, .groceries, .gas, .evCharging, .drugstore, .entertainment: .everyday
        case .flights, .hotels, .carRental, .travel, .transit: .travel
        case .wholesale, .homeImprovement, .shopping: .shoppingAndHome
        case .streaming, .telecom, .utilities, .office, .insurance: .billsAndServices
        case .fitness, .healthcare, .auto: .healthAndAuto
        case .other: .other
        }
    }

    var title: String {
        switch self {
        case .dining: "Dining"
        case .groceries: "Groceries"
        case .gas: "Gas"
        case .evCharging: "EV charging"
        case .flights: "Flights"
        case .hotels: "Hotels"
        case .carRental: "Car rentals"
        case .travel: "Other travel"
        case .transit: "Transit"
        case .streaming: "Streaming"
        case .drugstore: "Drugstore"
        case .entertainment: "Entertainment"
        case .wholesale: "Wholesale clubs"
        case .homeImprovement: "Home improvement"
        case .shopping: "Shopping"
        case .telecom: "Phone & internet"
        case .utilities: "Utilities"
        case .fitness: "Fitness & wellness"
        case .healthcare: "Healthcare"
        case .auto: "Auto & service"
        case .office: "Office & shipping"
        case .insurance: "Insurance"
        case .other: "Everything else"
        }
    }

    var symbol: String {
        switch self {
        case .dining: "fork.knife"
        case .groceries: "cart"
        case .gas: "fuelpump"
        case .evCharging: "bolt.car"
        case .flights: "airplane"
        case .hotels: "bed.double"
        case .carRental: "car"
        case .travel: "suitcase"
        case .transit: "tram"
        case .streaming: "play.tv"
        case .drugstore: "cross.case"
        case .entertainment: "ticket"
        case .wholesale: "shippingbox"
        case .homeImprovement: "hammer"
        case .shopping: "bag"
        case .telecom: "antenna.radiowaves.left.and.right"
        case .utilities: "bolt"
        case .fitness: "figure.run"
        case .healthcare: "stethoscope"
        case .auto: "wrench.and.screwdriver"
        case .office: "briefcase"
        case .insurance: "shield"
        case .other: "square.grid.2x2"
        }
    }
}

enum PeriodKind: String, Codable, Hashable {
    case monthly, quarterly, semiannual, annual
    /// Resets on the card's renewal (account anniversary) date; falls back to the calendar year when unknown.
    case cardmemberYear

    var title: String {
        switch self {
        case .monthly: "per calendar month"
        case .quarterly: "per calendar quarter"
        case .semiannual: "per calendar half-year"
        case .annual: "per calendar year"
        case .cardmemberYear: "per cardmember year"
        }
    }

    var months: Int {
        switch self {
        case .monthly: 1
        case .quarterly: 3
        case .semiannual: 6
        case .annual, .cardmemberYear: 12
        }
    }

    /// Inclusive start of the window containing `date`.
    func start(containing date: Date) -> Date {
        let p = Day.ymd(date)
        let m0 = ((p.m - 1) / months) * months + 1
        return Day.make(p.y, m0, 1)
    }

    /// Exclusive end.
    func end(from start: Date) -> Date { Day.addMonths(months, to: start) }
}

/// A benefit credit rule. Stores its source and version (design §4).
struct BenefitRule: Identifiable, Hashable {
    let id: String
    let version: Int
    let name: String
    let cap: Money
    let period: PeriodKind
    /// Lower-cased merchant keywords that make a purchase eligible.
    let merchantKeywords: [String]
    /// Categories that make a purchase eligible (used when no merchant list is configured).
    let eligibleCategories: Set<RewardCategory>
    /// Strong issuer credit descriptor for automatic confirmation.
    let creditDescriptor: String
    /// Days after a period closes that a late credit may still belong to it.
    let creditLagDays: Int
    let requiresEnrollment: Bool
    let sourceURL: URL
    let notes: String
    /// How the benefit reaches the cardholder. Only statement credits show up in the bank feed.
    var redemption: Redemption = .statementCredit
    /// Per-month cap overrides, e.g. Uber Cash is USD 15 most months and USD 35 in December.
    var capByMonth: [Int: Money] = [:]
    var certificate: CertificateSpec? = nil
    var reviewOverlappingPeriods = false

    enum Redemption: String, Hashable {
        /// Posts as a credit on the statement; matched automatically.
        case statementCredit = "statement"
        /// Loaded into a merchant app (Uber Cash, DoorDash promos, Lyft credit). Never on the statement; owner logs use.
        case appCredit = "app"
        /// A certificate in the loyalty account (hotel free night). Owner records issue, expiry and redemption.
        case certificate
        /// A complimentary membership (e.g. DashPass). Owner records activation.
        case membership

        var tracksPeriods: Bool { self == .statementCredit || self == .appCredit }

        var label: String {
            switch self {
            case .statementCredit: "Statement credit"
            case .appCredit: "In-app credit"
            case .certificate: "Award certificate"
            case .membership: "Membership"
            }
        }
    }

    func cap(for start: Date) -> Money { capByMonth[Day.ymd(start).m] ?? cap }

    func isEligible(_ t: Transaction) -> Bool {
        let text = "\(t.merchant) \(t.originalDescription)".lowercased()
        if !merchantKeywords.isEmpty {
            return merchantKeywords.contains { keyword in
                if keyword.count >= 6 && text.contains(keyword) { return true }
                let literal = NSRegularExpression.escapedPattern(for: keyword)
                return text.range(of: "(?<![\\p{L}\\p{N}])\(literal)(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
            }
        }
        return eligibleCategories.contains(t.category)
    }
}

/// A free-night (or similar) award certificate earned on a card.
struct CertificateSpec: Hashable {
    enum Trigger: Hashable {
        /// Issued after the card's renewal (account anniversary).
        case renewal
        /// Issued after spending a threshold in a calendar year.
        case calendarYearSpend(Money)
    }
    let trigger: Trigger
    /// Maximum award-night cost in points, if capped (e.g. 85,000 Marriott points).
    let pointsCap: Int?
    /// Text when the cap isn't points (e.g. "Category 1–4 hotel").
    let label: String?
    /// How long a certificate stays valid after it's issued.
    let validMonths: Int
    /// Typical delay between the trigger and the certificate appearing in the loyalty account.
    let issueLagWeeks: Int

    var capText: String {
        if let pointsCap { return "Up to \(pointsCap.formatted()) points" }
        return label ?? "Standard room, any eligible hotel"
    }
}

/// An earning rule for the rewards catalog (design §9 and the RewardRadar expansion).
struct EarnRule: Hashable {
    let categories: Set<RewardCategory>
    let multiplier: Double
    /// Bonus spend cap per period; spend beyond it earns the card's base rate.
    let spendCap: Money?
    let capPeriod: PeriodKind?
    /// When set, the bonus applies only to merchants matching one of these keywords.
    let merchantKeywords: [String]
    /// Bonus depends on a booking channel the feed cannot see (e.g. issuer travel portal).
    let channelRestricted: Bool
    let note: String?

    init(_ categories: Set<RewardCategory>, _ multiplier: Double, cap: Money? = nil, per period: PeriodKind? = nil,
         merchants: [String] = [], channelRestricted: Bool = false, note: String? = nil) {
        self.categories = categories
        self.multiplier = multiplier
        self.spendCap = cap
        self.capPeriod = period
        self.merchantKeywords = merchants
        self.channelRestricted = channelRestricted
        self.note = note
    }
}

struct RewardProgram: Identifiable, Hashable {
    let id: String
    let name: String
    let unit: String
    /// Default value per point in minor units (cents) of `currency`.
    let defaultCentsPerPoint: Double
    let currency: CurrencyCode
}

enum PlaidSupport: String, Decodable, Hashable {
    case oauth, credential, limited, unsupported

    var label: String {
        switch self {
        case .oauth: "OAuth"
        case .credential: "Bank sign-in"
        case .limited: "Limited"
        case .unsupported: "Unavailable"
        }
    }
}

struct CardProduct: Identifiable, Hashable {
    let id: String
    let name: String
    let issuer: String
    let market: CurrencyCode
    let network: String
    let annualFee: Money
    let foreignTransactionFee: Double
    let programID: String
    let baseMultiplier: Double
    let earnRules: [EarnRule]
    let benefits: [BenefitRule]
    let perks: [String]
    let color: CardStyle
    let artCode: String
    /// Lower-cased account-name keywords used to suggest this product when mapping a linked account.
    let matchKeywords: [String]
    let sourceURL: URL
    /// True once someone checked the issuer's current terms (recorded in the catalog source).
    let verified: Bool
    let checkedOn: String?
    let notes: String?
    let isBusiness: Bool
    let plaidSupport: PlaidSupport?

    var displayName: String { issuer == "Other" ? name : "\(issuer) \(name)" }
    var suggestsStatementImport: Bool { plaidSupport == .unsupported }
}

/// Card art colors from the catalog (hex).
struct CardStyle: Hashable {
    let from: String
    let to: String
    let lightText: Bool
}

// MARK: - Wallet

enum ConnectionState: Hashable {
    case plaid(institution: String)
    case csv
    case pdf
    case ofx
    case manual
    case reauthRequired(institution: String)
    case disconnectPending(institution: String)
    case disconnected(institution: String)

    var label: String {
        switch self {
        case .plaid(let i): "Plaid · \(i)"
        case .csv: "CSV import"
        case .pdf: "PDF statement"
        case .ofx: "OFX/QFX statement"
        case .manual: "Manual"
        case .reauthRequired: "Reconnect required"
        case .disconnectPending: "Disconnect pending"
        case .disconnected(let i): "Disconnected · \(i)"
        }
    }

    var needsReauth: Bool { if case .reauthRequired = self { true } else { false } }
}

struct Card: Identifiable, Hashable {
    let id: String
    var nickname: String
    var productID: String
    var mask: String?
    var openedOn: Date
    var renewal: RenewalDate?
    var connection: ConnectionState
    var lastSync: Date?
    var historyStart: Date
    var isAuthorizedUser: Bool = false
    /// Owner-service connection this card's source account belongs to (live data only).
    var connectionID: String? = nil
    /// True when `openedOn` is the start of covered history rather than a known open date.
    var openedIsEstimate: Bool = false
    var openDateStatus: OpenDateStatus = .confirmed
}

struct RenewalDate: Hashable {
    enum Precision: String { case day, month }
    enum Source: String {
        case issuer = "Issuer", owner = "Owner confirmed", inferredFromFee = "Inferred from posted fee"
        case openAnniversary = "Anniversary of confirmed open date"
    }
    var date: Date
    var precision: Precision
    var source: Source
}

enum TransactionKind: String, CaseIterable, Hashable {
    /// `offerCredit`: a card-linked offer paid as a statement credit (Amex Offers, Chase Offers, RBC Offers…).
    /// Merchant-funded and opted into, so it neither nets against category spend like a refund nor fills a
    /// card benefit like an issuer credit. It counts toward offers earned and, optionally, the effective fee.
    case purchase, refund, issuerCredit, issuerCreditReversal, offerCredit, fee, payment

    var title: String {
        switch self {
        case .purchase: "Purchase"
        case .refund: "Merchant refund"
        case .issuerCredit: "Statement credit"
        case .issuerCreditReversal: "Statement credit reversal"
        case .offerCredit: "Card-linked offer"
        case .fee: "Fee"
        case .payment: "Payment"
        }
    }
}

enum Provenance: String, Hashable {
    case plaid = "Plaid"
    case csv = "CSV import"
    case pdf = "PDF statement"
    case ofx = "OFX/QFX statement"
    case manual = "Manual"
}

struct Transaction: Identifiable, Hashable {
    let id: String
    let cardID: String
    /// Positive = money out (purchase, fee). Negative = money in (refund, credit, payment).
    let amount: Money
    let posted: Date
    let authorized: Date?
    let merchant: String
    let originalDescription: String
    let category: RewardCategory
    let kind: TransactionKind
    var pending: Bool = false
    var provenance: Provenance = .plaid
    var mcc: String? = nil
}
