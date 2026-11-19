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
        let text = (t.originalDescription ?? t.name).uppercased()
        if primary == "LOAN_PAYMENTS" || detailed == "TRANSFER_IN_ACCOUNT_TRANSFER" || text.contains("PAYMENT RECEIVED") || text.contains("PAYMENT THANK YOU") {
            return .payment
        }
        // Balance adjustments (credit-balance refund checks, debit/credit adjustments) move money, not rewards or benefits.
        if PlaidMapping.isBalanceAdjustment(text) { return .payment }
        // Only charges are fees. Plaid also files issuer credits like "AMEX Airline Fee Reimbursement" under BANK_FEES.
        if t.amountMinor > 0 && (primary == "BANK_FEES" || PlaidMapping.isAnnualFee(text) || PlaidMapping.isCardFee(text)) { return .fee }
        if t.amountMinor < 0 {
            // Strong issuer-credit wording applies even when Plaid fills merchantName or assigns a non-INCOME category.
            let strongCreditPhrase = ["STATEMENT CREDIT", "REIMBURSEMENT", "REBATE"].contains(where: text.contains)
            let issuerLike = t.merchantName == nil || primary == "INCOME" || primary == "TRANSFER_IN" || primary == "BANK_FEES"
            if strongCreditPhrase || (issuerLike && text.contains("CREDIT")) { return .issuerCredit }
            return .refund
        }
        return .purchase
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
        if let mcc = t.merchantCategoryCode.flatMap(Int.init), let c = category(mcc: mcc) { return c }
        switch t.categoryDetailed ?? "" {
        case "FOOD_AND_DRINK_GROCERIES": return .groceries
        case let d where d.hasPrefix("FOOD_AND_DRINK"): return .dining
        case "TRANSPORTATION_GAS": return .gas
        case "TRAVEL_FLIGHTS": return .flights
        case "TRAVEL_LODGING": return .hotels
        case "ENTERTAINMENT_TV_AND_MOVIES": return .streaming
        case "TRANSPORTATION_PUBLIC_TRANSIT", "TRANSPORTATION_TAXIS_AND_RIDE_SHARES": return .transit
        case "MEDICAL_PHARMACIES_AND_SUPPLEMENTS": return .drugstore
        case let d where d.hasPrefix("ENTERTAINMENT"): return .entertainment
        default: return .other
        }
    }

    /// Issuers assign bonus categories by merchant category code, so prefer it when Plaid supplies one.
    static func category(mcc: Int) -> RewardCategory? {
        switch mcc {
        case 3000...3299, 4511: .flights
        case 3501...3999, 7011: .hotels
        case 5812, 5813, 5814: .dining
        case 5411, 5422, 5441, 5451, 5462: .groceries
        case 5541, 5542, 5983: .gas
        case 4111, 4112, 4121, 4131: .transit
        case 5912: .drugstore
        case 4899: .streaming
        case 7832, 7922, 7929, 7991, 7996: .entertainment
        default: nil
        }
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
