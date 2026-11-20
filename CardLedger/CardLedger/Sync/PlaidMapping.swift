import Foundation

/// Normalized transaction as streamed by the Card Ledger API.
struct RemoteTransaction: Codable, Hashable {
    let id: String
    let accountId: String
    /// Plaid convention, already in minor units: positive = money out.
    let amountMinor: Int
    let currency: String?
    let currencyIsOfficial: Bool
    let date: String
    let authorizedDate: String?
    let name: String
    let merchantName: String?
    let originalDescription: String?
    let categoryPrimary: String?
    let categoryDetailed: String?
    let merchantCategoryCode: String?
    let pending: Bool
    let pendingTransactionId: String?
}

/// Classification of Plaid fields into the ledger's kinds and reward categories (design §8).
enum PlaidMapping {
    static func kind(_ t: RemoteTransaction) -> TransactionKind {
        let primary = t.categoryPrimary ?? ""
        let detailed = t.categoryDetailed ?? ""
        let text = statementDescription(t).uppercased()
        if primary == "LOAN_PAYMENTS" || detailed == "TRANSFER_IN_ACCOUNT_TRANSFER" || text.contains("PAYMENT RECEIVED") || text.contains("PAYMENT THANK YOU") {
            return .payment
        }
        // Balance adjustments (credit-balance refund checks, debit/credit adjustments) move money, not rewards or benefits.
        if PlaidMapping.isBalanceAdjustment(text) { return .payment }
        if t.amountMinor > 0 && isAmexHotelCredit(text) { return .issuerCreditReversal }
        // Only charges are fees. Plaid also files issuer credits like "AMEX Airline Fee Reimbursement" under BANK_FEES.
        if t.amountMinor > 0 && (primary == "BANK_FEES" || PlaidMapping.isAnnualFee(text) || PlaidMapping.isCardFee(text)) { return .fee }
        if t.amountMinor < 0 {
            // Strong issuer-credit wording applies even when Plaid fills merchantName or assigns a non-INCOME category.
            let strongCreditPhrase = isAmexHotelCredit(text)
                || ["STATEMENT CREDIT", "REIMBURSEMENT", "REBATE"].contains(where: text.contains)
            let issuerLike = t.merchantName == nil || primary == "INCOME" || primary == "TRANSFER_IN" || primary == "BANK_FEES"
            if strongCreditPhrase || (issuerLike && text.contains("CREDIT")) { return .issuerCredit }
            return .refund
        }
        return .purchase
    }

    static func isAmexHotelCredit(_ text: String) -> Bool {
        text.range(of: #"\b(?:AMEX|AMERICAN\s+EXPRESS|PLATINUM)\s+HOTEL\s*CREDIT\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The issuer's hotel credit marker can appear in the entry name instead of the raw description.
    static func hotelCreditDescription(_ description: String, alternate: String) -> String {
        guard !isAmexHotelCredit(description), isAmexHotelCredit(alternate) else { return description }
        return "\(description) · \(alternate)"
    }

    static func statementDescription(_ transaction: RemoteTransaction) -> String {
        let description = transaction.originalDescription ?? transaction.name
        return hotelCreditDescription(description, alternate: transaction.name)
    }

    /// Annual or renewal card fee, matched by pattern so issuer wording variants are covered:
    /// "ANNUAL FEE", "ANNUAL MEMBERSHIP FEE", "RENEWAL MEMBERSHIP FEE", "ANNUAL CARD FEE", "ADDITIONAL CARD ANNUAL FEE",
    /// "ANNUAL FEE - PRIMARY", "CARDMEMBER FEE", "YEARLY FEE", French "FRAIS ANNUELS" / "COTISATION ANNUELLE".
    /// A posted annual fee anchors the renewal date, so these stay specific to yearly card fees.
    static func isAnnualFee(_ upperText: String) -> Bool {
        !isFeeReversal(upperText) && annualFeePatterns.contains { matches($0, upperText) }
    }

    /// Card fees that are not the yearly renewal charge: instalments of the annual fee (Amex Canada Cobalt
    /// "MEMBERSHIP FEE INSTALLMENT"), monthly card or account fees, and additional-card fees.
    /// They are fees, not spend, but don't anchor the renewal date.
    static func isCardFee(_ upperText: String) -> Bool {
        !isFeeReversal(upperText) && !isAnnualFee(upperText) && cardFeePatterns.contains { matches($0, upperText) }
    }

    /// Credits and reversals that mention a fee ("ANNUAL FEE REBATE", "ANNUAL FEE WAIVED", "FEE REVERSAL").
    static func isFeeReversal(_ upperText: String) -> Bool {
        matches(feeReversalPattern, upperText)
    }

    private static let annualFeePatterns: [NSRegularExpression] = [
        // Up to two qualifying words between the period and FEE: ANNUAL [MEMBERSHIP|CARD|PRIMARY CARD] FEE(S).
        #"\b(?:ANNUAL|YEARLY|RENEWAL)\b(?:\s+[A-Z]+){0,2}?\s+FEES?\b"#,
        #"\bCARD\s?MEMBER(?:SHIP)?\s+FEES?\b"#,
        #"\b(?:FRAIS|COTISATION)\s+ANNUEL(?:LE)?S?\b"#,
    ].map(regex)

    private static let cardFeePatterns: [NSRegularExpression] = [
        #"\b(?:MEMBERSHIP|CARD|ACCOUNT|ANNUAL)\s+FEE\s+INSTAL{1,2}MENTS?\b"#,
        #"\bMONTHLY\s+(?:CARD|ACCOUNT|MEMBERSHIP)\s+FEES?\b"#,
        #"\b(?:ADDITIONAL|SUPPLEMENTARY|AUTHORI[SZ]ED\s+USER)\s+CARD(?:HOLDER)?\s+FEES?\b"#,
        #"\bFRAIS\s+(?:MENSUELS|DE\s+CARTE\s+SUPPL[EÉ]MENTAIRE)\b"#,
    ].map(regex)

    private static let feeReversalPattern = regex(#"\b(?:REIMBURSE\w*|CREDIT(?!\s+CARD)|REVERS\w*|WAIVE[DR]?|WAIVER|REFUND\w*|REBATE|ADJ(?:USTMENT)?|REMBOURSEMENT|REMISE)\b"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are fixed literals checked by EngineTests; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isBalanceAdjustment(_ upperText: String) -> Bool {
        ["REFUND CHECK", "CR BAL", "CREDIT BALANCE", "BALANCE REFUND", "ADJ FOR BAL", "ADJUSTMENT FOR BAL"].contains(where: upperText.contains)
    }

    static func category(_ t: RemoteTransaction) -> RewardCategory {
        if let c = MCCDirectory.category(forCode: t.merchantCategoryCode) { return c }

        let detailed = t.categoryDetailed ?? ""
        let primary = t.categoryPrimary ?? ""
        let text = (t.originalDescription ?? t.name).uppercased()

        // Plaid often groups wholesale clubs under GENERAL_MERCHANDISE_SUPERSTORES without an MCC.
        if detailed != "TRANSPORTATION_GAS", !text.contains("GAS"), !text.contains("FUEL"), !text.contains("PHARMACY"),
           ["COSTCO WHSE", "COSTCO WHOLESALE", "COSTCO.COM", "COSTCO.CA", "SAM'S CLUB", "SAMS CLUB", "BJ'S WHOLESALE", "BJS WHOLESALE"]
            .contains(where: text.contains) {
            return .wholesale
        }

        switch detailed {
        case let d where d == "FOOD_AND_DRINK_GROCERIES" || d.hasPrefix("FOOD_AND_GROCERIES"):
            return .groceries
        case let d where d.hasPrefix("FOOD_AND_DRINK"):
            return .dining
        case "TRANSPORTATION_GAS":
            return .gas
        case "TRANSPORTATION_EV_CHARGING":
            return .evCharging
        case "TRAVEL_FLIGHTS":
            return .flights
        case "TRAVEL_LODGING":
            return .hotels
        case "TRAVEL_RENTAL_CARS":
            return .carRental
        case let d where d.hasPrefix("TRAVEL"):
            return .travel
        case "TRANSPORTATION_PUBLIC_TRANSIT", "TRANSPORTATION_TAXIS_AND_RIDE_SHARES",
             "TRANSPORTATION_PARKING", "TRANSPORTATION_TOLLS":
            return .transit
        case "ENTERTAINMENT_TV_AND_MOVIES", "ENTERTAINMENT_MUSIC_AND_AUDIO", "ENTERTAINMENT_VIDEO_GAMES":
            return .streaming
        case let d where d.hasPrefix("ENTERTAINMENT"):
            return .entertainment
        case "MEDICAL_PHARMACIES_AND_SUPPLEMENTS":
            return .drugstore
        case let d where d.hasPrefix("MEDICAL"):
            return .healthcare
        case let d where d.hasPrefix("HOME_IMPROVEMENT"):
            return .homeImprovement
        case "RENT_AND_UTILITIES_INTERNET_AND_CABLE", "RENT_AND_UTILITIES_TELEPHONE":
            return .telecom
        case "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY", "RENT_AND_UTILITIES_WATER",
             "RENT_AND_UTILITIES_SEWAGE_AND_WASTE_MANAGEMENT", "RENT_AND_UTILITIES_OTHER_UTILITIES":
            return .utilities
        case "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS":
            return .fitness
        case "GENERAL_SERVICES_AUTOMOTIVE":
            return .auto
        case "GENERAL_SERVICES_INSURANCE":
            return .insurance
        case "GENERAL_MERCHANDISE_OFFICE_SUPPLIES", "GENERAL_SERVICES_POSTAGE_AND_SHIPPING":
            return .office
        case let d where d.hasPrefix("GENERAL_MERCHANDISE"):
            return .shopping
        default:
            break
        }

        switch primary {
        case "FOOD_AND_DRINK": return .dining
        case "TRAVEL": return .travel
        case "ENTERTAINMENT": return .entertainment
        case "HOME_IMPROVEMENT": return .homeImprovement
        case "MEDICAL": return .healthcare
        case "GENERAL_MERCHANDISE": return .shopping
        default: return .other
        }
    }

    /// Issuers assign bonus categories by merchant category code, so prefer it when Plaid supplies one.
    static func category(mcc: Int) -> RewardCategory? {
        MCCDirectory.category(for: mcc)
    }

    static func currency(_ t: RemoteTransaction) -> CurrencyCode? {
        guard t.currencyIsOfficial, let c = t.currency else { return nil }
        return CurrencyCode(rawValue: c)
    }

    static func displayMerchant(_ t: RemoteTransaction) -> String { t.merchantName ?? t.name }
}

extension Day {
    /// Parses a Plaid date-only string ("YYYY-MM-DD") without any time-zone shift.
    static func parse(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return make(p[0], p[1], p[2])
    }
}
