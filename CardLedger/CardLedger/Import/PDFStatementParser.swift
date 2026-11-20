import Foundation
import CryptoKit
#if canImport(PDFKit)
import PDFKit
#endif

enum PDFStatementError: Error, LocalizedError, Equatable {
    case unreadablePDF
    case passwordRequired
    case invalidPassword
    case noSelectableText

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            "This file could not be opened as a PDF document."
        case .passwordRequired:
            "This statement PDF is password-protected. Enter the password to unlock it locally."
        case .invalidPassword:
            "That password did not unlock the PDF. Try again."
        case .noSelectableText:
            "No selectable text was found in this PDF (it may be a scanned image). Download the digital statement PDF from your issuer's portal."
        }
    }
}

struct ParsedPDFTransaction: Identifiable, Hashable {
    let id: String
    var posted: Date
    var authorized: Date?
    var merchant: String
    var originalDescription: String
    var amount: Money
    var category: RewardCategory
    var kind: TransactionKind
    var include: Bool = true
    var rawLine: String
    var page: Int
    /// Where the row came from; CSV rows keep their own provenance in the ledger.
    var provenance: Provenance = .pdf
    /// Issuer reference for the row when the source has one (Amex CSV "Reference"), used as a stable source ID.
    var sourceKey: String? = nil
    /// Issuer's offer label for the row, e.g. Amex "ShopSmallOffer".
    var offerTag: String? = nil
}

struct ParsedPDFStatement: Hashable {
    var detectedIssuer: String?
    var detectedProductID: String?
    var accountMask: String?
    var currency: CurrencyCode
    var statementPeriodStart: Date?
    var statementPeriodEnd: Date?
    var statementClosingDate: Date?
    var paymentDueDate: Date?
    var transactions: [ParsedPDFTransaction]
    var warnings: [String]
}

/// On-device credit card PDF statement extractor and parser.
/// Runs 100% locally via `PDFKit` (no network calls, no third-party processor — preserves Design §6).
enum PDFStatementParser {
    // MARK: - PDFKit Extraction

    #if canImport(PDFKit)
    static func parse(data: Data, password: String? = nil, fallbackCurrency: CurrencyCode? = nil,
                      referenceToday: Date = Day.today) throws -> ParsedPDFStatement {
        let pages = try extractPages(from: data, password: password)
        return parse(pages: pages, fallbackCurrency: fallbackCurrency, referenceToday: referenceToday)
    }

    static func parse(url: URL, password: String? = nil, fallbackCurrency: CurrencyCode? = nil,
                      referenceToday: Date = Day.today) throws -> ParsedPDFStatement {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw PDFStatementError.unreadablePDF }
        return try parse(data: data, password: password, fallbackCurrency: fallbackCurrency, referenceToday: referenceToday)
    }

    /// Extracts layout-ordered text rows per page using `PDFSelection.selectionsByLine()` coordinate clustering,
    /// falling back to `PDFPage.string` when selection geometry is unavailable.
    static func extractPages(from data: Data, password: String? = nil) throws -> [[String]] {
        guard let doc = PDFDocument(data: data) else { throw PDFStatementError.unreadablePDF }
        if doc.isLocked {
            guard let password, !password.isEmpty else { throw PDFStatementError.passwordRequired }
            guard doc.unlock(withPassword: password) else { throw PDFStatementError.invalidPassword }
        }
        var pages: [[String]] = []
        var totalNonEmpty = 0
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let rows = extractVisualLines(from: page)
            totalNonEmpty += rows.count
            pages.append(rows)
        }
        guard totalNonEmpty > 0 else { throw PDFStatementError.noSelectableText }
        return pages
    }

    private static func extractVisualLines(from page: PDFPage) -> [String] {
        let bounds = page.bounds(for: .mediaBox)
        if let full = page.selection(for: bounds) {
            let pieces: [(y: CGFloat, x: CGFloat, text: String)] = full.selectionsByLine().compactMap { sel in
                let raw = (sel.string ?? "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return nil }
                let rect = sel.bounds(for: page)
                return (y: rect.midY, x: rect.minX, text: raw)
            }
            if !pieces.isEmpty {
                // PDF Y increases bottom-to-top; cluster fragments within 4pt into one visual table row.
                let sorted = pieces.sorted { a, b in
                    if abs(a.y - b.y) > 4.0 { return a.y > b.y }
                    return a.x < b.x
                }
                var rows: [[(y: CGFloat, x: CGFloat, text: String)]] = []
                for p in sorted {
                    if let last = rows.last?.first, abs(last.y - p.y) <= 4.0 {
                        rows[rows.count - 1].append(p)
                    } else {
                        rows.append([p])
                    }
                }
                return rows.map { row in
                    row.sorted { $0.x < $1.x }.map(\.text).joined(separator: "  ")
                }
            }
        }
        return (page.string ?? "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    #endif

    // MARK: - Pure Text Statement Parsing

    private enum StatementSection {
        case neutral
        case purchases
        case paymentsAndCredits
        case fees
        case interest
        /// Issuer-originated rows outside purchases, e.g. Amex "Other Account Transactions" (offers, monthly fees).
        case otherAccount
        case ignored
    }

    static func parse(pages: [[String]], fallbackCurrency: CurrencyCode? = nil,
                      referenceToday: Date = Day.today) -> ParsedPDFStatement {
        let allLines = pages.flatMap { $0 }
        let fullText = allLines.joined(separator: "\n")
        let headerText = pages.first?.prefix(45).joined(separator: "\n") ?? fullText

        let issuer = detectIssuer(in: fullText)
        let currency = fallbackCurrency ?? detectCurrency(in: fullText, issuer: issuer)
        let mask = detectMask(in: headerText) ?? detectMask(in: fullText)
        let (periodStart, periodEnd, closingDate) = detectStatementDates(in: allLines, referenceToday: referenceToday)
        let dueDate = detectDueDate(in: allLines, closingDate: closingDate ?? periodEnd, referenceToday: referenceToday)
        let productID = detectProductID(headerLines: pages.first ?? [], issuer: issuer, currency: currency)

        var section: StatementSection = .neutral
        var transactions: [ParsedPDFTransaction] = []
        var warnings: [String] = []
        var txCounter = 0

        for (pageIdx, lines) in pages.enumerated() {
            // Index of the row whose detail lines (foreign currency, routing, offer label) may follow.
            var detailOwner: Int?
            var detailLines = 0
            for line in lines {
                let cleaned = normalizeWhitespace(line)
                guard !cleaned.isEmpty else { continue }

                if let newSection = detectSectionHeading(cleaned) {
                    section = newSection
                    detailOwner = nil
                    continue
                }
                if section == .ignored { continue }
                if isNoiseOrSummaryLine(cleaned) { continue }

                if let parsed = parseTransactionLine(
                    cleaned,
                    page: pageIdx + 1,
                    section: section,
                    currency: currency,
                    periodStart: periodStart,
                    periodEnd: periodEnd ?? closingDate,
                    referenceToday: referenceToday,
                    counter: &txCounter
                ) {
                    transactions.append(parsed)
                    detailOwner = transactions.count - 1
                    detailLines = 0
                } else if let owner = detailOwner {
                    // Amex prints the offer label on the line under the credit ("ShopSmallOffer").
                    detailLines += 1
                    if detailLines > 4 || cleaned.uppercased().hasPrefix("TOTAL") {
                        detailOwner = nil
                    } else if transactions[owner].offerTag == nil, isOfferTag(cleaned) {
                        transactions[owner].offerTag = cleaned
                    }
                }
            }
        }

        markOfferCredits(&transactions)

        applyRewardCategoryHints(from: allLines, to: &transactions)

        if periodStart == nil && closingDate == nil {
            warnings.append("Statement billing period was not detected; verify transaction years.")
        }
        if transactions.isEmpty {
            warnings.append("No transaction rows matched standard credit-card statement formats. Verify this is a monthly statement PDF.")
        }

        return ParsedPDFStatement(
            detectedIssuer: issuer,
            detectedProductID: productID,
            accountMask: mask,
            currency: currency,
            statementPeriodStart: periodStart,
            statementPeriodEnd: periodEnd,
            statementClosingDate: closingDate ?? periodEnd,
            paymentDueDate: dueDate,
            transactions: transactions,
            warnings: warnings
        )
    }

    // MARK: - Shared Row Classification

    /// Kind, reward category and display merchant for one statement row, for other statement sources (CSV).
    static func classifyRow(description: String, amountMinor: Int) -> (kind: TransactionKind, category: RewardCategory, merchant: String) {
        let upper = description.uppercased()
        var kind = classifyKind(upperDescription: upper, amountMinor: amountMinor, section: .purchases)
        // Amex exports bill interest as a bare "INTEREST" row.
        if amountMinor > 0, upper == "INTEREST" || upper == "INTEREST CHARGES" { kind = .fee }
        return (kind, classifyCategory(upperDescription: upper, kind: kind), cleanMerchantName(from: description, kind: kind))
    }

    // MARK: - Card-linked Offers

    /// An issuer offer label such as "ShopSmallOffer", "BookstoreOffer" or "Grocery Offer" (Amex Canada).
    static func isOfferTag(_ text: String) -> Bool {
        text.count <= 45 && text.range(of: #"^[A-Za-z0-9&'.+\- ]{0,40}(?:Offer|OFFER)$"#, options: .regularExpression) != nil
    }

    /// Credits carrying an issuer offer label are card-linked offers, not merchant refunds.
    static func markOfferCredits(_ transactions: inout [ParsedPDFTransaction]) {
        for i in transactions.indices where transactions[i].offerTag != nil
            && transactions[i].amount.minor < 0 && transactions[i].kind != .payment {
            transactions[i].kind = .offerCredit
        }
    }

    // MARK: - Issuer Rewards Summary

    private struct CategoryHint {
        let posted: Date
        let minor: Int
        let tokens: Set<String>
        let category: RewardCategory
    }

    /// Amex statements list which rows earned an accelerated rate ("5 pts/$1 Eligible Food/Drink", then
    /// "MM/DD/YYYY MERCHANT $amount points"). That is the issuer's own classification, so use it to categorize
    /// rows the keyword rules left as "other".
    private static func applyRewardCategoryHints(from lines: [String], to transactions: inout [ParsedPDFTransaction]) {
        let headerPattern = #"(?i)^\d+(?:\.\d+)?\s*(?:pts?|points?|x)\s*/\s*\$1\s+eligible\s+(.+?)\s+-?\$[\d,]+\.\d{2}\s+-?[\d,]+$"#
        let rowPattern = #"^(\d{2})/(\d{2})/(\d{4})\s+(.+?)\s+(-?)\$([\d,]+\.\d{2})\s+-?[\d,]+$"#
        var current: RewardCategory?
        var hints: [CategoryHint] = []
        for raw in lines {
            let line = normalizeWhitespace(raw)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = matchRegex(headerPattern, in: line, ns: ns, range: full) {
                current = hintCategory(forLabel: ns.substring(with: m.range(at: 1)).uppercased())
                continue
            }
            guard let category = current, let m = matchRegex(rowPattern, in: line, ns: ns, range: full),
                  let mo = Int(ns.substring(with: m.range(at: 1))), let d = Int(ns.substring(with: m.range(at: 2))),
                  let y = Int(ns.substring(with: m.range(at: 3))), let date = validatedDate(y: y, m: mo, d: d),
                  let value = Double(ns.substring(with: m.range(at: 6)).replacingOccurrences(of: ",", with: ""))
            else { continue }
            let sign = ns.substring(with: m.range(at: 5)) == "-" ? -1 : 1
            hints.append(CategoryHint(posted: date, minor: Int((value * 100).rounded()) * sign,
                                      tokens: meaningfulTokens(ns.substring(with: m.range(at: 4))), category: category))
        }
        guard !hints.isEmpty else { return }
        var used = Set<Int>()
        for i in transactions.indices {
            let t = transactions[i]
            guard t.category == .other, t.kind == .purchase || t.kind == .refund else { continue }
            let tokens = meaningfulTokens(t.originalDescription)
            if let h = hints.indices.first(where: { j in
                !used.contains(j) && hints[j].minor == t.amount.minor
                    && abs(Day.days(from: hints[j].posted, to: t.posted)) <= 1
                    && !hints[j].tokens.intersection(tokens).isEmpty
            }) {
                used.insert(h)
                transactions[i].category = hints[h].category
            }
        }
    }

    private static func hintCategory(forLabel label: String) -> RewardCategory? {
        if label.contains("GROCER") || label.contains("SUPERMARKET") { return .groceries }
        if label.contains("FOOD") || label.contains("DRINK") || label.contains("DINING") || label.contains("RESTAURANT") { return .dining }
        if label.contains("STREAM") || label.contains("DIGITAL MEDIA") { return .streaming }
        if label.contains("CAR RENTAL") || label.contains("RENTAL CAR") { return .carRental }
        if label.contains("HOTEL") || label.contains("LODGING") { return .hotels }
        if label.contains("FLIGHT") || label.contains("AIRLINE") || label.contains("AIR TRAVEL") { return .flights }
        if label.contains("TRAVEL") { return .travel }
        if label.contains("TRANSIT") || label.contains("RIDE") { return .transit }
        if label.contains("EV CHARG") || label.contains("ELECTRIC VEHICLE") { return .evCharging }
        if label.contains("GAS") || label.contains("FUEL") { return .gas }
        if label.contains("DRUG") || label.contains("PHARMAC") { return .drugstore }
        if label.contains("ENTERTAINMENT") { return .entertainment }
        if label.contains("WHOLESALE") { return .wholesale }
        if label.contains("HOME IMPROVEMENT") || label.contains("HARDWARE") || label.contains("FURNITURE") { return .homeImprovement }
        if label.contains("WIRELESS") || label.contains("PHONE") || label.contains("INTERNET") || label.contains("TELECOM") { return .telecom }
        if label.contains("UTILIT") || label.contains("RECURRING") { return .utilities }
        if label.contains("FITNESS") || label.contains("WELLNESS") || label.contains("GYM") { return .fitness }
        if label.contains("HEALTH") || label.contains("MEDICAL") { return .healthcare }
        if label.contains("OFFICE") || label.contains("SHIPPING") { return .office }
        if label.contains("INSURANCE") { return .insurance }
        if label.contains("RETAIL") || label.contains("SHOPPING") { return .shopping }
        return nil
    }

    // MARK: - Deterministic Source ID & Deduplication

    /// Deterministic source ID so importing the same statement PDF twice is idempotent, while preserving
    /// legitimate duplicate same-day charges (e.g. two identical coffees on the same day via `occurrenceIndex`).
    static func sourceID(cardID: String, transaction: ParsedPDFTransaction, occurrenceIndex: Int) -> String {
        // Issuer references (Amex CSV) are unique per row, so re-imports stay idempotent without hashing.
        if let key = transaction.sourceKey { return "csv:\(cardID):\(key)" }
        let normDesc = normalizeDescriptionForHash(transaction.originalDescription)
        let digest = SHA256.hash(data: Data(normDesc.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "pdf:\(cardID):\(Day.key(transaction.posted)):\(transaction.amount.minor):\(hex):\(occurrenceIndex)"
    }

    static func occurrenceKey(for transaction: ParsedPDFTransaction) -> String {
        "\(Day.key(transaction.posted))|\(transaction.amount.minor)|\(normalizeDescriptionForHash(transaction.originalDescription))"
    }

    static func normalizeDescriptionForHash(_ text: String) -> String {
        text.uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Checks whether a parsed PDF transaction matches an already-stored ledger transaction on the same card
    /// (e.g., from Plaid or an earlier overlapping statement).
    static func matchesExisting(_ parsed: ParsedPDFTransaction, existing: Transaction) -> Bool {
        guard parsed.amount == existing.amount else { return false }
        let dayDiff = abs(Day.days(from: parsed.posted, to: existing.posted))
        guard dayDiff <= 2 else { return false }
        let aTokens = meaningfulTokens(parsed.originalDescription + " " + parsed.merchant)
        let bTokens = meaningfulTokens(existing.originalDescription + " " + existing.merchant)
        if aTokens.isEmpty || bTokens.isEmpty { return dayDiff == 0 }
        return !aTokens.intersection(bTokens).isEmpty
    }

    private static func meaningfulTokens(_ s: String) -> Set<String> {
        let stop: Set<String> = ["THE", "INC", "LLC", "LTD", "CORP", "COM", "WWW", "USA", "CAN", "PAYMENT", "CARD"]
        return Set(
            s.uppercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 && !stop.contains($0) && Int($0) == nil }
        )
    }

    // MARK: - Transaction Line Parser

    private static func parseTransactionLine(
        _ line: String,
        page: Int,
        section: StatementSection,
        currency: CurrencyCode,
        periodStart: Date?,
        periodEnd: Date?,
        referenceToday: Date,
        counter: inout Int
    ) -> ParsedPDFTransaction? {
        // Strip optional small leading item/line index (e.g. "1  Nov 12  Nov 13  ..." or "001  ...")
        let working = stripLeadingItemNumber(line)

        // 1. Parse first date at start of line.
        guard let first = extractLeadingDate(from: working, periodStart: periodStart, periodEnd: periodEnd, referenceToday: referenceToday) else {
            return nil
        }

        var remainder = first.rest.trimmingCharacters(in: .whitespaces)
        var authorized: Date? = nil
        var posted = first.date

        // 2. Check for an optional second date (Trans Date + Post Date layout).
        if let second = extractLeadingDate(from: remainder, periodStart: periodStart, periodEnd: periodEnd, referenceToday: referenceToday) {
            authorized = first.date
            posted = second.date
            remainder = second.rest.trimmingCharacters(in: .whitespaces)
        }

        // 3. Extract trailing monetary amount (must have cents `.dd` and not be a percentage).
        guard let amountMatch = extractTrailingAmount(from: remainder) else { return nil }
        let description = cleanRawDescription(amountMatch.before)
        guard !description.isEmpty, !isSummaryDescription(description) else { return nil }

        // 4. Determine signed amount & transaction kind.
        let upper = description.uppercased()
        var signedMinor = amountMatch.minor
        if !amountMatch.hasExplicitSign {
            if section == .paymentsAndCredits && !isChargeReversal(upper) {
                signedMinor = -abs(signedMinor)
            } else if looksLikeImplicitNegative(upper) {
                signedMinor = -abs(signedMinor)
            }
        }
        guard signedMinor != 0 else { return nil }

        let kind = classifyKind(upperDescription: upper, amountMinor: signedMinor, section: section)
        let merchant = cleanMerchantName(from: description, kind: kind)
        let category = classifyCategory(upperDescription: upper, kind: kind)

        counter += 1
        return ParsedPDFTransaction(
            id: "pdf-preview-\(page)-\(counter)",
            posted: posted,
            authorized: authorized,
            merchant: merchant,
            originalDescription: description,
            amount: Money(signedMinor, currency),
            category: category,
            kind: kind,
            include: true,
            rawLine: line,
            page: page
        )
    }

    private static func stripLeadingItemNumber(_ line: String) -> String {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Strip a 1–3 digit leading item sequence index (common on Home Trust / Canadian statements)
        // when followed by a recognized date format, without eating the day of a `DD MMM` date.
        guard let numMatch = matchRegex(#"^(\d{1,3})\s+"#, in: line, ns: ns, range: full) else { return line }
        let rest = ns.substring(from: numMatch.range.upperBound)
        let restNS = rest as NSString
        let restFull = NSRange(location: 0, length: restNS.length)

        // Followed directly by YYYY-MM-DD or MM/DD(/YY|/YYYY)
        if matchRegex(#"^(?:\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:/\d{2,4})?)(?=\s|$)"#, in: rest, ns: restNS, range: restFull) != nil {
            return rest
        }
        // Followed by MMM DD (e.g. "1 Nov 12 Nov 13 ..."). Guard against `DD MMM DD MMM` (e.g. "12 Nov 13 Nov SHOP").
        if let m = matchRegex(#"^([A-Za-zÀ-ÿ]{3,9})\.?\s+(\d{1,2})(?=\s|$)"#, in: rest, ns: restNS, range: restFull),
           monthMap[restNS.substring(with: m.range(at: 1)).uppercased()] != nil {
            let afterFirst = restNS.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespaces)
            let afterNS = afterFirst as NSString
            let afterFull = NSRange(location: 0, length: afterNS.length)
            // If what follows `MMM DD` is another month name WITHOUT a day after it (e.g. "12 Nov 13 Nov SHOP"),
            // then the leading number was actually the first day of `DD MMM`.
            if let m2 = matchRegex(#"^([A-Za-zÀ-ÿ]{3,9})\.?(?:\s+(\d{1,2}))?(?=\s|$)"#, in: afterFirst, ns: afterNS, range: afterFull),
               monthMap[afterNS.substring(with: m2.range(at: 1)).uppercased()] != nil {
                if m2.range(at: 2).location == NSNotFound {
                    return line
                }
            }
            return rest
        }
        return line
    }

    private struct DateExtract {
        let date: Date
        let rest: String
    }

    private static let monthMap: [String: Int] = [
        "JAN": 1, "JANUARY": 1, "JANV": 1, "JANVIER": 1,
        "FEB": 2, "FEBRUARY": 2, "FEV": 2, "FÉV": 2, "FEVR": 2, "FÉVR": 2, "FEVRIER": 2, "FÉVRIER": 2,
        "MAR": 3, "MARCH": 3, "MARS": 3,
        "APR": 4, "APRIL": 4, "AVR": 4, "AVRIL": 4,
        "MAY": 5, "MAI": 5,
        "JUN": 6, "JUNE": 6, "JUIN": 6,
        "JUL": 7, "JULY": 7, "JUIL": 7, "JUILLET": 7,
        "AUG": 8, "AUGUST": 8, "AOU": 8, "AOÛ": 8, "AOUT": 8, "AOÛT": 8,
        "SEP": 9, "SEPT": 9, "SEPTEMBER": 9, "SEPTEMBRE": 9,
        "OCT": 10, "OCTOBER": 10, "OCTOBRE": 10,
        "NOV": 11, "NOVEMBER": 11, "NOVEMBRE": 11,
        "DEC": 12, "DECEMBER": 12, "DÉC": 12, "DECEMBRE": 12, "DÉCEMBRE": 12,
    ]

    private static func extractLeadingDate(
        from text: String,
        periodStart: Date?,
        periodEnd: Date?,
        referenceToday: Date
    ) -> DateExtract? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Format A: YYYY-MM-DD
        if let m = matchRegex(#"^(\d{4})-(\d{2})-(\d{2})(?=\s|$)"#, in: text, ns: ns, range: full),
           let y = Int(ns.substring(with: m.range(at: 1))),
           let mo = Int(ns.substring(with: m.range(at: 2))),
           let d = Int(ns.substring(with: m.range(at: 3))),
           let date = validatedDate(y: y, m: mo, d: d) {
            return DateExtract(date: date, rest: ns.substring(from: m.range.upperBound))
        }

        // Format B: MM/DD/YYYY or MM/DD/YY
        if let m = matchRegex(#"^(\d{1,2})/(\d{1,2})/(\d{2,4})(?=\s|$)"#, in: text, ns: ns, range: full),
           let mo = Int(ns.substring(with: m.range(at: 1))),
           let d = Int(ns.substring(with: m.range(at: 2))),
           let rawY = Int(ns.substring(with: m.range(at: 3))) {
            let y = rawY < 100 ? 2000 + rawY : rawY
            if let date = validatedDate(y: y, m: mo, d: d) {
                return DateExtract(date: date, rest: ns.substring(from: m.range.upperBound))
            }
        }

        // Format C: MM/DD (no year)
        if let m = matchRegex(#"^(\d{1,2})/(\d{1,2})(?=\s)"#, in: text, ns: ns, range: full),
           let mo = Int(ns.substring(with: m.range(at: 1))),
           let d = Int(ns.substring(with: m.range(at: 2))),
           (1...12).contains(mo), (1...31).contains(d),
           let date = resolveDateWithoutYear(month: mo, day: d, periodStart: periodStart, periodEnd: periodEnd, referenceToday: referenceToday) {
            return DateExtract(date: date, rest: ns.substring(from: m.range.upperBound))
        }

        // Format D: MMM DD, YYYY | MMM DD YYYY | MMM DD (e.g. "Nov 12, 2026", "NOV 12", "Sept. 05")
        if let m = matchRegex(#"^([A-Za-zÀ-ÿ]{3,9})\.?\s+(\d{1,2})(?:(?:,\s*|\s+)(\d{4}))?(?=\s|$)"#, in: text, ns: ns, range: full) {
            let monKey = ns.substring(with: m.range(at: 1)).uppercased()
            if let mo = monthMap[monKey], let d = Int(ns.substring(with: m.range(at: 2))), (1...31).contains(d) {
                let yearRange = m.range(at: 3)
                if yearRange.location != NSNotFound, let y = Int(ns.substring(with: yearRange)),
                   let date = validatedDate(y: y, m: mo, d: d) {
                    return DateExtract(date: date, rest: ns.substring(from: m.range.upperBound))
                } else if let date = resolveDateWithoutYear(month: mo, day: d, periodStart: periodStart, periodEnd: periodEnd, referenceToday: referenceToday) {
                    return DateExtract(date: date, rest: ns.substring(from: m.range.upperBound))
                }
            }
        }

        // Format E: DD MMM YYYY | DD MMM (e.g. "12 Nov 2026", "12 NOV")
        if let m = matchRegex(#"^(\d{1,2})\s+([A-Za-zÀ-ÿ]{3,9})\.?(?:\s+(\d{4}))?(?=\s|$)"#, in: text, ns: ns, range: full) {
            let monKey = ns.substring(with: m.range(at: 2)).uppercased()
            if let mo = monthMap[monKey], let d = Int(ns.substring(with: m.range(at: 1))), (1...31).contains(d) {
                let yearRange = m.range(at: 3)
                if yearRange.location != NSNotFound, let y = Int(ns.substring(with: yearRange)),
                   let date = validatedDate(y: y, m: mo, d: d) {
                    return DateExtract(date: date, rest: ns.substring(from: m.range.upperBound))
                } else if let date = resolveDateWithoutYear(month: mo, day: d, periodStart: periodStart, periodEnd: periodEnd, referenceToday: referenceToday) {
                    return DateExtract(date: date, rest: ns.substring(from: m.range.upperBound))
                }
            }
        }

        return nil
    }

    private static func validatedDate(y: Int, m: Int, d: Int) -> Date? {
        guard (1990...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.calendar = Day.calendar
        comps.timeZone = Day.calendar.timeZone
        comps.year = y; comps.month = m; comps.day = d
        guard let date = Day.calendar.date(from: comps) else { return nil }
        let check = Day.ymd(date)
        return (check.y == y && check.m == m && check.d == d) ? date : nil
    }

    /// Resolves a month/day without a year using the statement billing window (handling Dec → Jan wraparound).
    static func resolveDateWithoutYear(
        month: Int,
        day: Int,
        periodStart: Date?,
        periodEnd: Date?,
        referenceToday: Date
    ) -> Date? {
        if let start = periodStart, let end = periodEnd {
            let sy = Day.ymd(start).y
            let ey = Day.ymd(end).y
            if sy == ey {
                return validatedDate(y: ey, m: month, d: day)
            }
            // Cross-year statement (e.g., Dec 15, 2025 – Jan 14, 2026)
            if let candEnd = validatedDate(y: ey, m: month, d: day), candEnd <= Day.add(10, to: end) {
                return candEnd
            }
            if let candStart = validatedDate(y: sy, m: month, d: day) {
                return candStart
            }
        }
        if let end = periodEnd {
            let p = Day.ymd(end)
            // If transaction month is well after the statement closing month (e.g. Dec on a Jan statement), it's prior year.
            let y = (month > p.m + 1) ? (p.y - 1) : p.y
            return validatedDate(y: y, m: month, d: day)
        }
        let ref = Day.ymd(referenceToday)
        if let cand = validatedDate(y: ref.y, m: month, d: day) {
            if Day.days(from: referenceToday, to: cand) > 35 {
                return validatedDate(y: ref.y - 1, m: month, d: day) ?? cand
            }
            return cand
        }
        return nil
    }

    private struct AmountExtract {
        let minor: Int
        let hasExplicitSign: Bool
        let before: String
    }

    private static func extractTrailingAmount(from text: String) -> AmountExtract? {
        // Reject percentages at end of line (e.g., "24.99%")
        if text.trimmingCharacters(in: .whitespaces).hasSuffix("%") { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Matches: optional leading sign/paren/currency + digits with required `.dd` + optional closing paren / trailing CR / sign / currency.
        let pattern = #"(?:^|\s)([+\-−]?)\s*(\(?)\s*(?:(?:CA|US)?\$|CAD\s+|USD\s+)?([+\-−]?)\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})\s*(\)?)\s*(CR|-|−)?(?:\s*(?:CAD|USD))?\s*$"#
        guard let m = matchRegex(pattern, in: text, ns: ns, range: full) else { return nil }

        let sign1 = ns.substring(with: m.range(at: 1))
        let openParen = ns.substring(with: m.range(at: 2))
        let sign2 = ns.substring(with: m.range(at: 3))
        let numberStr = ns.substring(with: m.range(at: 4)).replacingOccurrences(of: ",", with: "")
        let closeParen = ns.substring(with: m.range(at: 5))
        let suffix = m.range(at: 6).location != NSNotFound ? ns.substring(with: m.range(at: 6)).uppercased() : ""

        // Require balanced parentheses if either is present.
        if (openParen == "(") != (closeParen == ")") { return nil }
        guard let value = Double(numberStr), value.isFinite, value > 0, value < 1_000_000 else { return nil }

        let isNegative = sign1 == "-" || sign1 == "−"
            || sign2 == "-" || sign2 == "−"
            || openParen == "("
            || suffix == "CR" || suffix == "-" || suffix == "−"
        let hasExplicitSign = isNegative || sign1 == "+" || sign2 == "+"
        let minor = Int((value * 100).rounded()) * (isNegative ? -1 : 1)
        let before = ns.substring(to: m.range.location)
        return AmountExtract(minor: minor, hasExplicitSign: hasExplicitSign, before: before)
    }

    // MARK: - Metadata Extraction

    private static func detectStatementDates(in lines: [String], referenceToday: Date) -> (start: Date?, end: Date?, closing: Date?) {
        var periodStart: Date?
        var periodEnd: Date?
        var closingDate: Date?

        let rangeRegex = #"([A-Za-zÀ-ÿ]{3,9}\.?\s+\d{1,2}(?:,?\s+\d{4})?|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2})\s*(?:to|through|thru|[-–—])\s*([A-Za-zÀ-ÿ]{3,9}\.?\s+\d{1,2},?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2})"#
        let singleRegex = #"([A-Za-zÀ-ÿ]{3,9}\.?\s+\d{1,2},?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2})"#

        let scanned = Array(lines.prefix(80))
        for (index, line) in scanned.enumerated() {
            let upper = line.uppercased()
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            // Column labels with the dates on the same or the following rows, without a "to"/dash separator.
            if periodStart == nil, upper.contains("CLOSING DATE"),
               upper.contains("OPENING DATE") || upper.contains("PERIOD") || upper.contains("START DATE") {
                for candidate in scanned[index..<min(index + 3, scanned.count)] {
                    let cns = candidate as NSString
                    let dates = explicitDates(in: candidate, ns: cns, pattern: singleRegex, referenceToday: referenceToday)
                    guard dates.count >= 2 else { continue }
                    let (d1, d2) = (dates[dates.count - 2], dates[dates.count - 1])
                    if d1 <= d2, Day.days(from: d1, to: d2) <= 45 {
                        periodStart = d1
                        periodEnd = d2
                        if closingDate == nil { closingDate = d2 }
                        break
                    }
                }
            }

            if periodStart == nil,
               let m = matchRegex(rangeRegex, in: line, ns: ns, range: full) {
                let s1 = ns.substring(with: m.range(at: 1))
                let s2 = ns.substring(with: m.range(at: 2))
                if let d2 = parseExplicitDate(s2, referenceToday: referenceToday) {
                    let d1 = parseExplicitDate(s1, referenceToday: d2)
                        ?? extractLeadingDate(from: s1 + " ", periodStart: nil, periodEnd: d2, referenceToday: d2)?.date
                    if let d1, d1 <= d2, Day.days(from: d1, to: d2) <= 45 {
                        periodStart = d1
                        periodEnd = d2
                    }
                }
            }

            if closingDate == nil,
               ["STATEMENT DATE", "CLOSING DATE", "BILLING DATE", "STATEMENT CLOSING", "NEW BALANCE AS OF"].contains(where: upper.contains),
               let m = matchRegex(singleRegex, in: line, ns: ns, range: full),
               let d = parseExplicitDate(ns.substring(with: m.range(at: 1)), referenceToday: referenceToday) {
                closingDate = d
            }
        }
        return (periodStart, periodEnd, closingDate)
    }

    private static func explicitDates(in text: String, ns: NSString, pattern: String, referenceToday: Date) -> [Date] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            parseExplicitDate(ns.substring(with: $0.range(at: 1)), referenceToday: referenceToday)
        }
    }

    private static func detectDueDate(in lines: [String], closingDate: Date?, referenceToday: Date) -> Date? {
        let singleRegex = #"([A-Za-zÀ-ÿ]{3,9}\.?\s+\d{1,2},?\s+\d{4}|\d{1,2}\s+[A-Za-zÀ-ÿ]{3,9}\.?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2})"#
        let yearlessRegex = #"([A-Za-zÀ-ÿ]{3,9}\.?\s+\d{1,2}|\d{1,2}\s+[A-Za-zÀ-ÿ]{3,9}\.?|\d{1,2}/\d{1,2})(?=\s|$)"#
        let dueKeywords = [
            "PAYMENT DUE", "DUE DATE", "PLEASE PAY BY", "PAY BY", "DUE BY",
            "PAYMENT MUST BE RECEIVED BY", "DATE D'ÉCHÉANCE", "DATE D'ECHEANCE",
            "DATE LIMITE DE PAIEMENT", "PAIEMENT DÛ", "PAIEMENT DU",
        ]
        let scanned = Array(lines.prefix(90))
        for (index, line) in scanned.enumerated() {
            let upper = line.uppercased()
            guard let keywordRange = dueKeywords.compactMap({ upper.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
                continue
            }

            // 1. Prefer an explicit date appearing after the due-date label on the same line
            // (handles multi-column headers like "Closing Date: 11/14/2026  Payment Due Date: 12/09/2026").
            let afterLabel = String(line[keywordRange.upperBound...])
            let afterNS = afterLabel as NSString
            let afterDates = explicitDates(in: afterLabel, ns: afterNS, pattern: singleRegex, referenceToday: referenceToday)
            if let first = afterDates.first {
                return first
            }

            // 2. Yearless date after the due-date label when statement closing date is known (e.g. "Payment Due Date: Jan 12").
            if let closingDate,
               let d = extractYearlessDueDate(in: afterLabel, pattern: yearlessRegex, closingDate: closingDate) {
                return d
            }

            // 3. Explicit date earlier on the same line (when the line doesn't also carry another statement date label).
            let hasOtherDateLabel = upper.contains("CLOSING DATE") || upper.contains("STATEMENT DATE") || upper.contains("OPENING DATE")
            if !hasOtherDateLabel {
                let ns = line as NSString
                if let d = explicitDates(in: line, ns: ns, pattern: singleRegex, referenceToday: referenceToday).first {
                    return d
                }
            }

            // 4. Stacked-header table layout (label on row N, date value on row N+1 or N+2).
            for candidate in scanned[(index + 1)..<min(index + 3, scanned.count)] {
                let cns = candidate as NSString
                let dates = explicitDates(in: candidate, ns: cns, pattern: singleRegex, referenceToday: referenceToday)
                if !dates.isEmpty {
                    if let closingDate,
                       let afterClose = dates.first(where: {
                           let gap = Day.days(from: closingDate, to: $0)
                           return (1...45).contains(gap)
                       }) {
                        return afterClose
                    }
                    if !hasOtherDateLabel {
                        return dates[0]
                    }
                    if dates.count >= 2 {
                        return dates.last
                    }
                }
                if let closingDate, !hasOtherDateLabel,
                   let d = extractYearlessDueDate(in: candidate, pattern: yearlessRegex, closingDate: closingDate) {
                    return d
                }
            }
        }
        return nil
    }

    private static func extractYearlessDueDate(in text: String, pattern: String, closingDate: Date) -> Date? {
        let ns = text as NSString
        guard let m = matchRegex(pattern, in: text, ns: ns, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let token = ns.substring(with: m.range(at: 1))
        guard let ext = extractLeadingDate(from: token + " ", periodStart: nil, periodEnd: nil, referenceToday: closingDate) else {
            return nil
        }
        let parts = Day.ymd(ext.date)
        let closeY = Day.ymd(closingDate).y
        for year in [closeY, closeY + 1] {
            if let cand = validatedDate(y: year, m: parts.m, d: parts.d) {
                let gap = Day.days(from: closingDate, to: cand)
                if (1...45).contains(gap) { return cand }
            }
        }
        return nil
    }

    private static func parseExplicitDate(_ text: String, referenceToday: Date) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ext = extractLeadingDate(from: trimmed + " ", periodStart: nil, periodEnd: nil, referenceToday: referenceToday) else {
            return nil
        }
        // Only treat as explicit if the source string contained a 2- or 4-digit year.
        let hasYear = trimmed.range(of: #"\d{4}|/\d{2}$"#, options: .regularExpression) != nil
        return hasYear ? ext.date : nil
    }

    private static func detectIssuer(in fullText: String) -> String? {
        let upper = fullText.uppercased()
        let signatures: [(keywords: [String], issuer: String)] = [
            (["HOME TRUST", "HOMETRUST"], "Home Trust"),
            (["ROBINHOOD GOLD CARD", "ROBINHOOD CREDIT", "COASTAL COMMUNITY BANK"], "Robinhood"),
            (["BILT REWARDS", "BILT PALLADIUM", "BILT OBSIDIAN", "BILT BLUE", "CARDLESS", "COLUMN N.A."], "Bilt"),
            (["APPLE CARD", "GOLDMAN SACHS BANK USA", "GS BANK USA"], "Apple"),
            (["WEALTHSIMPLE"], "Wealthsimple"),
            (["ROGERS BANK", "ROGERS RED"], "Rogers Bank"),
            (["PC FINANCIAL", "PRESIDENT'S CHOICE BANK", "PRESIDENTS CHOICE", "PC INSIDERS", "PC WORLD ELITE"], "PC Financial"),
            (["CANADIAN TIRE BANK", "TRIANGLE WORLD ELITE", "TRIANGLE MASTERCARD", "CTFS.COM"], "Canadian Tire Bank"),
            (["MBNA"], "MBNA"),
            (["AMERICAN EXPRESS", "AMEX"], "American Express"),
            (["JPMORGAN CHASE", "CHASE CARD SERVICES", "CHASE.COM", "SAPPHIRE RESERVE", "SAPPHIRE PREFERRED"], "Chase"),
            (["CAPITAL ONE"], "Capital One"),
            (["CITIBANK", "CITICARDS", "CITI CARDS", "CITI STRATA"], "Citi"),
            (["BANK OF AMERICA", "ATMOS REWARDS"], "Bank of America"),
            (["WELLS FARGO"], "Wells Fargo"),
            (["DISCOVER"], "Discover"),
            (["U.S. BANK", "US BANK", "USBANK"], "U.S. Bank"),
            (["ROYAL BANK OF CANADA", "RBC ROYAL BANK", "RBC AVION"], "RBC"),
            (["TD CANADA TRUST", "TORONTO-DOMINION", "TD AEROPLAN", "TD REWARDS"], "TD"),
            (["CIBC", "CANADIAN IMPERIAL BANK"], "CIBC"),
            (["BANK OF MONTREAL", "BMO"], "BMO"),
            (["SCOTIABANK", "BANK OF NOVA SCOTIA"], "Scotiabank"),
            (["TANGERINE"], "Tangerine"),
            (["SIMPLII FINANCIAL", "SIMPLII"], "Simplii Financial"),
            (["NATIONAL BANK OF CANADA", "BANQUE NATIONALE"], "National Bank"),
        ]
        for entry in signatures {
            if entry.keywords.contains(where: upper.contains) {
                return entry.issuer
            }
        }
        return nil
    }

    private static func detectCurrency(in fullText: String, issuer: String?) -> CurrencyCode {
        let upper = fullText.uppercased()
        let canadianOnly: Set<String> = [
            "Home Trust", "MBNA", "Rogers Bank", "PC Financial", "Canadian Tire Bank",
            "Wealthsimple", "RBC", "TD", "CIBC", "BMO", "Scotiabank", "Tangerine",
            "Simplii Financial", "National Bank",
        ]
        let usOnly: Set<String> = [
            "Apple", "Robinhood", "Bilt", "Chase", "Citi", "Bank of America",
            "Wells Fargo", "Discover", "U.S. Bank",
        ]
        if let issuer {
            if canadianOnly.contains(issuer) { return .cad }
            if usOnly.contains(issuer) { return .usd }
        }
        if upper.contains("CANADIAN DOLLARS") || upper.contains("CAD") || upper.contains("CA$")
            || upper.contains("BANK OF CANADA") || upper.contains("AMERICANEXPRESS.CA") || upper.contains("AMEX.CA")
            || upper.range(of: #"\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z]\s?\d[ABCEGHJ-NPRSTV-Z]\d\b"#, options: .regularExpression) != nil {
            return .cad
        }
        return .usd
    }

    private static func detectMask(in text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let patterns = [
            #"(?:[Xx\*•]{4})\s?(?:[Xx\*•]{5}\d)\s?(\d{5})\b"#,
            #"(?i)(?:card|account)\s+(?:number\s+)?(?:ending(?:\s+in)?|#|no\.?)\s*[:\-]?\s*(?:[Xx\*•]{4}[\s\-]?){0,3}(\d{4})\b"#,
            #"(?:[Xx\*•]{4}[\s\-]?){2,3}(\d{4})\b"#,
            #"(?i)ending\s+in\s+(\d{4})\b"#,
        ]
        for pattern in patterns {
            if let m = matchRegex(pattern, in: text, ns: ns, range: full) {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    private static func detectProductID(headerLines: [String], issuer: String?, currency: CurrencyCode) -> String? {
        let sample = headerLines.prefix(35).joined(separator: " ")
        let suggested = Catalog.suggest(accountName: sample, institution: issuer, currency: currency.rawValue)
        if suggested.issuer != "Other" { return suggested.id }
        if let issuer {
            let fallback = Catalog.suggest(accountName: issuer, institution: issuer, currency: currency.rawValue)
            if fallback.issuer != "Other" { return fallback.id }
        }
        return nil
    }

    // MARK: - Section & Noise Detection

    private static func detectSectionHeading(_ line: String) -> StatementSection? {
        // Real section headings do not carry a trailing dollar amount.
        guard extractTrailingAmount(from: line) == nil, line.count <= 80 else { return nil }
        let upper = line.uppercased()
            .replacingOccurrences(of: "[^A-Z0-9&/,\\- ]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let ignoredHeadings = [
            "INTEREST CHARGE CALCULATION", "ACCOUNT SUMMARY", "REWARDS SUMMARY", "POINTS SUMMARY",
            "CASH BACK SUMMARY", "CASHBACK SUMMARY", "PAYMENT INFORMATION", "IMPORTANT INFORMATION",
            "IMPORTANT MESSAGES", "TOTALS YEAR-TO-DATE", "YEAR-TO-DATE", "YEAR TO DATE",
            "FEE SUMMARY", "ANNUAL PERCENTAGE RATE", "TERMS AND CONDITIONS", "DAILY CASH SUMMARY",
            "MEMBERSHIP REWARDS", "SUMMARY OF POINTS", "ABOUT YOUR INTEREST", "ABOUT YOUR STATEMENT",
        ]
        if ignoredHeadings.contains(where: upper.contains) { return .ignored }

        let paymentHeadings = [
            "PAYMENTS AND CREDITS", "PAYMENTS & CREDITS", "PAYMENTS, CREDITS", "PAYMENTS AND OTHER CREDITS",
            "PAYMENTS & OTHER CREDITS", "CREDITS AND ADJUSTMENTS", "OTHER CREDITS", "PAYMENTS RECEIVED",
            "REFUNDS AND CREDITS", "PAYMENTS", "NEW PAYMENTS",
        ]
        if upper.hasPrefix("OTHER ACCOUNT TRANSACTIONS") { return .otherAccount }
        if paymentHeadings.contains(where: { upper == $0 || upper.hasPrefix($0) }) { return .paymentsAndCredits }

        let purchaseHeadings = [
            "PURCHASES", "NEW CHARGES", "STANDARD PURCHASES", "TRANSACTIONS", "TRANSACTION DETAILS",
            "ACCOUNT ACTIVITY", "CARD ACTIVITY", "PURCHASES AND ADJUSTMENTS", "PURCHASES & ADJUSTMENTS",
            "CHARGES", "DEBITS", "ACTIVITY DETAIL",
            // Amex Canada: "Your Transactions", then "New Transactions for <cardmember>" per card on the account.
            "YOUR TRANSACTIONS", "NEW TRANSACTIONS",
        ]
        if purchaseHeadings.contains(where: { upper == $0 || upper.hasPrefix($0) }) { return .purchases }

        if upper == "FEES" || upper == "FEES CHARGED" || upper.hasPrefix("FEES CHARGED") { return .fees }
        if upper == "INTEREST" || upper == "INTEREST CHARGED" || upper.hasPrefix("INTEREST CHARGED") { return .interest }
        return nil
    }

    private static func isNoiseOrSummaryLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        let exactOrPrefixNoise = [
            "PREVIOUS BALANCE", "NEW BALANCE", "OPENING BALANCE", "CLOSING BALANCE",
            "STATEMENT BALANCE", "MINIMUM PAYMENT", "CREDIT LIMIT", "AVAILABLE CREDIT",
            "BALANCE FORWARD", "SUBTOTAL", "TOTAL PURCHASES", "TOTAL PAYMENTS",
            "TOTAL CREDITS", "TOTAL FEES", "TOTAL INTEREST", "TOTAL NEW BALANCE",
            "TOTAL THIS PERIOD", "TOTAL FOR THIS PERIOD", "TOTAL ACTIVITY",
            "FOREIGN CURRENCY", "EXCHANGE RATE", "TRANS DATE", "TRANSACTION DATE",
            "POST DATE", "POSTING DATE", "CONTINUED ON NEXT PAGE", "CONTINUED FROM PREVIOUS PAGE",
        ]
        if exactOrPrefixNoise.contains(where: { upper.hasPrefix($0) || upper.contains("  \($0)") }) { return true }
        if upper.range(of: #"^PAGE\s+\d+\s+OF\s+\d+"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func isSummaryDescription(_ desc: String) -> Bool {
        let upper = desc.uppercased()
        let blocked = [
            "PREVIOUS BALANCE", "NEW BALANCE", "OPENING BALANCE", "CLOSING BALANCE",
            "BALANCE FORWARD", "TOTAL PURCHASES", "TOTAL PAYMENTS", "TOTAL CREDITS",
            "TOTAL FEES", "TOTAL INTEREST", "MINIMUM PAYMENT", "CREDIT LIMIT",
            "AVAILABLE CREDIT", "SUBTOTAL", "STATEMENT BALANCE", "TOTAL NEW CHARGES",
        ]
        return blocked.contains(where: upper.contains)
    }

    private static func isChargeReversal(_ upper: String) -> Bool {
        upper.contains("RETURNED PAYMENT")
            || upper.contains("REVERSAL OF PAYMENT")
            || upper.contains("INSUFFICIENT FUNDS")
            || upper.contains("DISHONORED PAYMENT")
            || upper.contains("DISHONOURED PAYMENT")
            || upper.range(of: #"\bNSF\b"#, options: .regularExpression) != nil
    }

    private static func looksLikeImplicitNegative(_ upper: String) -> Bool {
        [
            "PAYMENT - THANK YOU", "PAYMENT THANK YOU", "PAYMENT RECEIVED", "AUTOPAY PAYMENT",
            "ONLINE PAYMENT", "PAIEMENT MERCI", "PAIEMENT RECU", "PAIEMENT REÇU",
            "STATEMENT CREDIT", "REIMBURSEMENT", "REBATE", "CASH BACK CREDIT", "CASHBACK CREDIT",
        ].contains(where: upper.contains)
    }

    // MARK: - Classification & Merchant Cleanup

    private static func classifyKind(upperDescription upper: String, amountMinor: Int, section: StatementSection) -> TransactionKind {
        if PlaidMapping.isBalanceAdjustment(upper) { return .payment }
        if [
            "PAYMENT - THANK YOU", "PAYMENT THANK YOU", "PAYMENT RECEIVED", "AUTOPAY",
            "ONLINE PAYMENT", "MOBILE PAYMENT", "ELECTRONIC PAYMENT", "PAIEMENT",
            "PRE-AUTHORIZED PAYMENT", "BILL PAYMENT", "DIRECT DEBIT PAYMENT",
            "ACH DEPOSIT", "ACH PAYMENT", "EFT PAYMENT", "APPLE CASH PAYMENT",
        ].contains(where: upper.contains) {
            return .payment
        }
        if amountMinor > 0 {
            if PlaidMapping.isAmexHotelCredit(upper) { return .issuerCreditReversal }
            if section == .fees || section == .interest || section == .otherAccount
                || PlaidMapping.isAnnualFee(upper) || PlaidMapping.isCardFee(upper)
                || ["INTEREST CHARGE", "FINANCE CHARGE", "LATE FEE", "LATE PAYMENT FEE",
                    "FOREIGN TRANSACTION FEE", "CASH ADVANCE FEE", "OVERLIMIT FEE", "OVER-LIMIT FEE"]
                .contains(where: upper.contains) {
                return .fee
            }
            return .purchase
        }
        // Negative amount (money in): distinguish issuer benefit credits from merchant refunds.
        let strongCredit = [
            "STATEMENT CREDIT", "REIMBURSEMENT", "REBATE", "ENTERTAINMENT CREDIT",
            "DINING CREDIT", "TRAVEL CREDIT", "FLIGHT CREDIT", "RESORT CREDIT",
            "HOTEL CREDIT", "AIRLINE FEE", "CLEAR CREDIT", "RESY CREDIT", "LULULEMON CREDIT",
            "OURA RING CREDIT", "UBER ONE CREDIT", "WALMART+ CREDIT", "EQUINOX CREDIT",
            "DUNKIN CREDIT", "DISNEY BUNDLE CREDIT", "RIDESHARE CREDIT", "HILTON CREDIT",
            "THE EDIT CREDIT", "CASH BACK CREDIT", "CASHBACK CREDIT", "REWARDS CREDIT",
            "DAILY CASH", "ANNUAL FEE CREDIT",
        ].contains(where: upper.contains)
        if strongCredit || (upper.contains("CREDIT") && (upper.contains("AMEX") || upper.contains("PLATINUM")
            || upper.contains("ASPIRE") || upper.contains("BRILLIANT") || upper.contains("CHASE")
            || upper.contains("CITI") || upper.contains("BILT") || upper.contains("ROBINHOOD"))) {
            return .issuerCredit
        }
        return .refund
    }

    private static func classifyCategory(upperDescription upper: String, kind: TransactionKind) -> RewardCategory {
        guard kind == .purchase || kind == .refund else { return .other }
        let rules: [(RewardCategory, substrings: [String], words: [String])] = [
            (.flights, [
                "AIR CANADA", "WESTJET", "PORTER AIR", "DELTA AIR", "UNITED AIR", "UNITED 016",
                "AMERICAN AIR", "ALASKA AIR", "JETBLUE", "SOUTHWEST", "AIRLINES", "AIRWAYS",
                "LUFTHANSA", "BRITISH AIR", "AIR FRANCE", "CATHAY",
            ], ["KLM", "ANA", "JAL"]),
            (.carRental, [
                "HERTZ", "AVIS RENT", "BUDGET RENT", "ENTERPRISE RENT", "NATIONAL CAR",
                "ALAMO RENT", "THRIFTY CAR", "DOLLAR RENT", "RENT-A-CAR", "CAR RENTAL",
            ], ["AVIS", "SIXT", "TURO"]),
            (.hotels, [
                "HILTON", "MARRIOTT", "HYATT", "WESTIN", "SHERATON", "COURTYARD", "FAIRFIELD",
                "CONRAD", "WALDORF", "DOUBLETREE", "HAMPTON INN", "HOLIDAY INN",
                "FOUR SEASONS", "FAIRMONT", "RITZ-CARLTON", "RITZ CARLTON", "ST. REGIS",
                "AIRBNB", "HOTEL", "RESORT", "MOTEL",
            ], ["IHG", "INN"]),
            (.travel, [
                "EXPEDIA", "BOOKING.COM", "PRICELINE", "ORBITZ", "AGODA", "HOPPER",
                "ROYAL CARIBBEAN", "CARNIVAL CRUISE", "NORWEGIAN CRUISE", "PRINCESS CRUISE",
                "CELEBRITY CRUISE", "HOLLAND AMERICA", "DISNEY CRUISE", "TRAVEL AGENCY",
            ], ["CRUISE", "CRUISES"]),
            // EV charging must precede gas so "SHELL RECHARGE" classifies as EV charging, not gas.
            (.evCharging, [
                "TESLA SUPERCHARGER", "SUPERCHARGER", "CHARGEPOINT", "ELECTRIFY AMERICA",
                "ELECTRIFY CANADA", "BLINK CHARGING", "FLO CHARGING", "IVY CHARGING",
                "SHELL RECHARGE", "EV CHARGING",
            ], ["EVGO"]),
            // Gas brands are matched as whole words so "TELUS MOBILITY" or "ESPRESSO" don't read as fuel.
            // Gas must precede wholesale so "COSTCO GAS" classifies as gas.
            (.gas, [
                "PETRO-CANADA", "PETRO CANADA", "ULTRAMAR", "CIRCLE K", "CO-OP GAS",
                "COSTCO GAS", "GAS STATION",
            ], ["BP", "SHELL", "EXXON", "EXXONMOBIL", "MOBIL", "CHEVRON", "SUNOCO", "TEXACO", "ARCO",
                "ESSO", "PIONEER", "IRVING", "HUSKY", "FUEL"]),
            // Drugstore must precede wholesale and healthcare so "COSTCO PHARMACY" classifies as drugstore.
            (.drugstore, [
                "WALGREENS", "RITE AID", "SHOPPERS DRUG", "REXALL", "LONDON DRUGS",
                "JEAN COUTU", "PHARMAPRIX", "PHARMACY", "DRUG MART", "DRUGSTORE",
            ], ["CVS"]),
            (.wholesale, [
                "COSTCO WHSE", "COSTCO WHOLESALE", "COSTCO.COM", "COSTCO.CA",
                "SAM'S CLUB", "SAMS CLUB", "BJ'S WHOLESALE", "BJS WHOLESALE",
            ], ["COSTCO"]),
            (.groceries, [
                "WHOLE FOODS", "TRADER JOE", "KROGER", "SAFEWAY", "PUBLIX", "WEGMANS",
                "ALDI", "H-E-B", "SPROUTS", "LOBLAWS", "NO FRILLS", "SOBEYS",
                "FARM BOY", "FRESHCO", "FOOD BASICS", "SUPERSTORE", "T&T SUPERMARKET",
                "REAL CANADIAN SUPER", "LONGOS", "LONGO'S", "PROVIGO",
                "SUPERMARKET", "GROCERY", "GROCER",
            ], ["METRO", "IGA", "MAXI"]),
            (.streaming, [
                "NETFLIX", "DISNEY+", "DISNEY PLUS", "HULU", "SPOTIFY", "APPLE.COM/BILL",
                "YOUTUBE", "YOUTUBEPREMIUM", "PEACOCK", "PARAMOUNT+", "MAX.COM",
                "PRIME VIDEO", "CRUNCHYROLL", "NYTIMES", "NEW YORK TIMES",
                "WALL STREET JOURNAL", "AUDIBLE", "SIRIUSXM",
            ], ["HBO", "WSJ", "CRAVE"]),
            (.transit, [
                "UBER *TRIP", "UBER TRIP", "LYFT", "PRESTO", "GO TRANSIT",
                "TRANSLINK", "NYCT", "WMATA", "CALTRAIN", "AMTRAK",
                "VIA RAIL", "PARKING", "EZPASS", "E-ZPASS", "407 ETR", "TAXI", "LIME*",
            ], ["TTC", "STM", "MTA", "BART", "CAB"]),
            (.dining, [
                "RESTAURANT", "CAFE", "COFFEE", "STARBUCKS", "TIM HORTONS", "BLUE BOTTLE",
                "DUNKIN", "MCDONALD", "CHIPOTLE", "SWEETGREEN", "SHAKE SHACK", "FIVE GUYS",
                "PANERA", "SUBWAY", "PIZZA", "SUSHI", "RAMEN", "GRILL", "BISTRO", "BAKERY",
                "TAVERN", "DINER", "KITCHEN", "STEAKHOUSE", "BURGER",
                "UBER EATS", "UBEREATS", "DOORDASH", "GRUBHUB", "SKIPTHEDISHES", "CAVIAR",
                "CHEESECAKE FACTORY", "RESY", "TOAST *",
                "SKIP THE DISHES", "FANTUAN", "HEYTEA", "HEY TEA", "BUBBLE TEA", "NOODLE", "DUMPLING",
                "EATERY", "TAQUERIA",
            ], ["BAR", "PUB", "BOBA", "PHO", "BBQ", "TACO", "TACOS"]),
            (.entertainment, [
                "TICKETMASTER", "STUBHUB", "SEATGEEK", "VIVID SEATS",
                "CINEPLEX", "CINEMA", "THEATRE", "THEATER", "MUSEUM",
                "BOWLING", "CONCERT", "LIVE NATION", "BROADWAY",
            ], ["AMC", "REGAL"]),
            (.telecom, [
                "AT&T", "VERIZON", "T-MOBILE", "TMOBILE", "COMCAST", "XFINITY", "SPECTRUM",
                "ROGERS WIRELESS", "ROGERS CABLE", "ROGERS COMM", "BELL MOBILITY", "BELL CANADA",
                "TELUS", "KOODO", "FREEDOM MOBILE", "VIRGIN PLUS", "VIDEOTRON", "MINT MOBILE",
                "GOOGLE FI", "STARLINK", "PUBLIC MOBILE",
            ], ["FIDO", "FIZZ", "SHAW"]),
            (.utilities, [
                "CON EDISON", "CONED", "PG&E", "DUKE ENERGY", "HYDRO ONE", "TORONTO HYDRO",
                "BC HYDRO", "HYDRO-QUEBEC", "HYDRO QUEBEC", "ENBRIDGE", "FORTISBC",
                "WASTE MANAGEMENT", "ELECTRIC UTILITY", "WATER UTILITY",
            ], []),
            (.homeImprovement, [
                "HOME DEPOT", "LOWE'S", "LOWES", "ACE HARDWARE", "HOME HARDWARE",
                "CANADIAN TIRE", "MENARDS", "SHERWIN-WILLIAMS", "SHERWIN WILLIAMS",
                "WAYFAIR", "CRATE & BARREL", "CRATE AND BARREL", "POTTERY BARN", "WEST ELM",
            ], ["RONA", "IKEA"]),
            (.fitness, [
                "EQUINOX", "PELOTON", "GOODLIFE", "PLANET FITNESS", "LIFE TIME",
                "ORANGETHEORY", "SOULCYCLE", "CLASSPASS", "LA FITNESS", "24 HOUR FITNESS",
                "ANYTIME FITNESS", "CROSSFIT", "PILATES",
            ], ["YMCA", "GYM", "YOGA"]),
            (.healthcare, [
                "DENTAL", "DENTIST", "ORTHODONT", "OPTOMETR", "MEDICAL CENTER",
                "URGENT CARE", "LABCORP", "QUEST DIAG", "CHIROPRACT", "PHYSIOTHERAPY",
                "DERMATOLOG", "OPHTHALMOLOG", "HOSPITAL",
            ], ["CLINIC", "PHYSIO"]),
            (.auto, [
                "JIFFY LUBE", "FIRESTONE", "GOODYEAR", "AUTOZONE", "O'REILLY AUTO",
                "ADVANCE AUTO", "NAPA AUTO", "KAL TIRE", "MEINEKE", "VALVOLINE",
                "CAR WASH", "AUTO REPAIR", "AUTO BODY",
            ], ["MIDAS"]),
            (.office, [
                "STAPLES", "OFFICE DEPOT", "OFFICEMAX", "FEDEX", "UPS STORE", "CANADA POST",
                "PUROLATOR", "ULINE", "VISTAPRINT", "AMAZON WEB SERVICES", "GOOGLE ADS",
                "META ADS",
            ], ["USPS", "DHL", "UPS", "AWS", "GITHUB"]),
            (.insurance, [
                "GEICO", "STATE FARM", "PROGRESSIVE INS", "ALLSTATE", "LIBERTY MUTUAL",
                "INTACT INS", "TD INSURANCE", "BELAIRDIRECT", "SONNET INS", "DESJARDINS INS",
                "MANULIFE", "SUN LIFE", "INSURANCE",
            ], ["AVIVA"]),
            (.shopping, [
                "AMAZON", "AMZN", "TARGET", "WALMART", "BEST BUY", "APPLE STORE", "APPLE.COM",
                "SEPHORA", "LULULEMON", "NORDSTROM", "MACY'S", "MACYS", "BLOOMINGDALE",
                "HUDSON'S BAY", "HOLT RENFREW", "UNIQLO", "OLD NAVY", "BARNES & NOBLE",
                "SPORT CHEK", "DECATHLON", "WINNERS", "MARSHALLS", "TJ MAXX", "HOMESENSE",
                "INDIGO", "CHAPTERS",
            ], ["ZARA", "NIKE", "ADIDAS", "ULTA", "ETSY", "EBAY", "REI", "GAP"]),
        ]
        let text = upper
        for (cat, substrings, words) in rules {
            // Substrings must start a word ("UBER EATS", "AIRLINES"); short brand words must match whole.
            if substrings.contains(where: { containsToken(text, $0, wholeWord: false) }) { return cat }
            if words.contains(where: { containsToken(text, $0, wholeWord: true) }) { return cat }
        }
        return .other
    }

    /// Finds `token` in `text` starting at a word boundary, and also ending at one when `wholeWord` is set.
    static func containsToken(_ text: String, _ token: String, wholeWord: Bool) -> Bool {
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var searchStart = text.startIndex
        while let r = text.range(of: token, range: searchStart..<text.endIndex) {
            let startsWord = r.lowerBound == text.startIndex || !isWordChar(text[text.index(before: r.lowerBound)])
                || !(token.first.map(isWordChar) ?? true)
            let endsWord = !wholeWord || r.upperBound == text.endIndex || !isWordChar(text[r.upperBound])
                || !(token.last.map(isWordChar) ?? true)
            if startsWord && endsWord { return true }
            searchStart = text.index(after: r.lowerBound)
        }
        return false
    }

    private static func cleanRawDescription(_ raw: String) -> String {
        var s = normalizeWhitespace(raw)
        // Strip leading long numeric reference codes (e.g., 8+ digit card-network ref IDs on statement tables)
        if let r = s.range(of: #"^\d{8,}\s+"#, options: .regularExpression) {
            s = String(s[r.upperBound...])
        }
        // Strip trailing Apple Card Daily Cash column (e.g. "2% $0.14" or "3% $1.20")
        if let r = s.range(of: #"\s+\d{1,2}%\s+\$?\d+(?:,\d{3})*\.\d{2}$"#, options: .regularExpression) {
            let candidate = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { s = candidate }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMerchantName(from rawDescription: String, kind: TransactionKind) -> String {
        if kind == .payment { return "Payment" }
        var s = rawDescription
        // Strip common POS/payment-processor prefixes for display while preserving originalDescription verbatim.
        for prefix in ["SQ *", "TST* ", "TST*", "SP ", "PAYPAL *", "AplPay ", "APLPAY ", "GOOGLE *"] {
            if s.uppercased().hasPrefix(prefix.uppercased()) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        // Strip trailing city + 2-letter US/CA state/province code (e.g., "TORONTO ON", "NEW YORK NY").
        if let r = s.range(of: #"\s+[A-Z]{2,}(?:\s+[A-Z]{2,})?\s+(?:ON|QC|BC|AB|MB|SK|NS|NB|NL|PE|YT|NT|NU|AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)$"#,
                           options: .regularExpression) {
            let trimmed = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3 { s = trimmed }
        }
        // Strip store numbers like "#0821" or "#1042" at the end.
        if let r = s.range(of: #"\s*#\d+$"#, options: .regularExpression) {
            let trimmed = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3 { s = trimmed }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return rawDescription }
        // Title-case ALL-CAPS merchant strings while preserving mixed-case text.
        if s == s.uppercased() && s.rangeOfCharacter(from: .letters) != nil {
            return s.localizedCapitalized
        }
        return s
    }

    private static func normalizeWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchRegex(_ pattern: String, in text: String, ns: NSString, range: NSRange) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, options: [], range: range)
    }
}
