import Foundation
#if canImport(CoreGraphics) && canImport(CoreText) && canImport(PDFKit)
import CoreGraphics
import CoreText
import PDFKit
#endif

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
    let refToday = Day.make(2026, 11, 19)

    // 1. Home Trust Preferred Visa (CAD, item numbers, two-date MMM dd, positive-printed payment in PAYMENTS AND CREDITS)
    do {
        let pages: [[String]] = [[
            "Home Trust Preferred Visa",
            "Account Number: XXXX XXXX XXXX 4821",
            "Statement Period: Oct 15, 2026 - Nov 14, 2026",
            "Payment Due Date: Dec 05, 2026",
            "Previous Balance  $512.00",
            "PAYMENTS AND CREDITS",
            "1  Oct 20  Oct 21  PAYMENT - THANK YOU  450.00",
            "2  Oct 25  Oct 26  AMAZON.CA REFUND  42.19 CR",
            "PURCHASES",
            "3  Oct 18  Oct 19  LOBLAWS #1042 TORONTO ON  114.23",
            "4  Nov 02  Nov 03  TIM HORTONS #4012 TORONTO ON  6.45",
            "Total Purchases  $120.68",
            "INTEREST CHARGE CALCULATION",
            "11/14/2026  Standard Purchases  19.99%",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        check(stmt.detectedIssuer == "Home Trust", "Home Trust issuer detected (got \(stmt.detectedIssuer ?? "nil"))")
        check(stmt.detectedProductID == "home-trust-preferred", "Home Trust product detected (got \(stmt.detectedProductID ?? "nil"))")
        check(stmt.currency == .cad, "Home Trust currency should be CAD (got \(stmt.currency.rawValue))")
        check(stmt.accountMask == "4821", "Home Trust mask should be 4821 (got \(stmt.accountMask ?? "nil"))")
        check(stmt.statementPeriodStart == Day.make(2026, 10, 15), "Period start should be 2026-10-15")
        check(stmt.statementPeriodEnd == Day.make(2026, 11, 14), "Period end should be 2026-11-14")
        check(stmt.paymentDueDate == Day.make(2026, 12, 5), "Payment due date should be 2026-12-05")
        check(stmt.transactions.count == 4, "Home Trust should parse 4 transactions (got \(stmt.transactions.count))")
        if stmt.transactions.count == 4 {
            let pay = stmt.transactions[0]
            check(pay.amount == Money(-45000, .cad), "Payment in PAYMENTS AND CREDITS should be -450.00 CAD (got \(pay.amount.formatted))")
            check(pay.kind == .payment, "Payment kind should be .payment")
            check(pay.authorized == Day.make(2026, 10, 20) && pay.posted == Day.make(2026, 10, 21), "Payment dates should be Oct 20 / Oct 21")

            let refund = stmt.transactions[1]
            check(refund.amount == Money(-4219, .cad), "CR refund should be -42.19 CAD (got \(refund.amount.formatted))")
            check(refund.kind == .refund, "Merchant refund should be .refund")

            let loblaws = stmt.transactions[2]
            check(loblaws.amount == Money(11423, .cad), "Loblaws should be +114.23 CAD")
            check(loblaws.category == .groceries, "Loblaws should categorize as groceries (got \(loblaws.category.rawValue))")
            check(loblaws.merchant == "Loblaws", "Merchant cleanup strips city/province/store# (got '\(loblaws.merchant)')")
            check(loblaws.originalDescription == "LOBLAWS #1042 TORONTO ON", "Original description preserved verbatim")

            let tims = stmt.transactions[3]
            check(tims.amount == Money(645, .cad), "Tim Hortons should be +6.45 CAD")
            check(tims.category == .dining, "Tim Hortons should categorize as dining")
        }
    }

    // 2. Robinhood Gold Card (USD, MM/DD/YYYY, negative credits & parenthesized autopay)
    do {
        let pages: [[String]] = [[
            "Robinhood Gold Card",
            "Issued by Coastal Community Bank",
            "Card ending in 9104",
            "Billing Cycle: 10/10/2026 - 11/09/2026",
            "ACCOUNT ACTIVITY",
            "10/14/2026  WHOLE FOODS MARKET AUSTIN TX  $88.42",
            "10/22/2026  ROBINHOOD GOLD STATEMENT CREDIT  -$15.00",
            "11/01/2026  AUTOPAY PAYMENT  ($512.40)",
            "Minimum Payment Due  $35.00",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        check(stmt.detectedIssuer == "Robinhood", "Robinhood issuer detected")
        check(stmt.detectedProductID == "robinhood-gold-card", "Robinhood Gold product detected (got \(stmt.detectedProductID ?? "nil"))")
        check(stmt.currency == .usd, "Robinhood currency is USD")
        check(stmt.accountMask == "9104", "Robinhood mask is 9104")
        check(stmt.transactions.count == 3, "Robinhood should parse 3 transactions (got \(stmt.transactions.count))")
        if stmt.transactions.count == 3 {
            check(stmt.transactions[0].category == .groceries && stmt.transactions[0].amount == Money(8842, .usd), "Whole Foods purchase parsed")
            check(stmt.transactions[1].kind == .issuerCredit && stmt.transactions[1].amount == Money(-1500, .usd), "Statement credit classified as .issuerCredit")
            check(stmt.transactions[2].kind == .payment && stmt.transactions[2].amount == Money(-51240, .usd), "Parenthesized autopay parsed as negative payment")
        }
    }

    // 3. Bilt 2.0 / Cardless (Column N.A., MM/DD two-date layout, annual fee & statement credit)
    do {
        let pages: [[String]] = [[
            "Bilt Palladium Card",
            "Issued by Column N.A. · Serviced by Cardless",
            "Account # ****-****-****-7732",
            "Statement Closing Date: 11/12/2026",
            "PURCHASES",
            "10/18  10/19  SWEETGREEN NEW YORK NY  $18.75",
            "10/28  10/29  BILT STATEMENT CREDIT  $25.00 CR",
            "FEES CHARGED",
            "11/01  11/01  ANNUAL MEMBERSHIP FEE  $495.00",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        check(stmt.detectedIssuer == "Bilt", "Bilt issuer detected")
        check(stmt.detectedProductID == "bilt-palladium", "Bilt Palladium product detected (got \(stmt.detectedProductID ?? "nil"))")
        check(stmt.currency == .usd, "Bilt currency is USD")
        check(stmt.accountMask == "7732", "Bilt mask is 7732")
        check(stmt.transactions.count == 3, "Bilt should parse 3 rows (got \(stmt.transactions.count))")
        if stmt.transactions.count == 3 {
            check(stmt.transactions[0].posted == Day.make(2026, 10, 19) && stmt.transactions[0].category == .dining, "Sweetgreen dining on Oct 19")
            check(stmt.transactions[1].kind == .issuerCredit && stmt.transactions[1].amount == Money(-2500, .usd), "Bilt credit is .issuerCredit")
            check(stmt.transactions[2].kind == .fee && stmt.transactions[2].amount == Money(49500, .usd), "Annual fee classified as .fee")
        }
    }

    // 4. Apple Card (Goldman Sachs Bank USA, Daily Cash column cleanup, ACH Deposit under Payments)
    do {
        let pages: [[String]] = [[
            "Apple Card",
            "Goldman Sachs Bank USA",
            "Statement Period: Oct 1, 2026 – Oct 31, 2026",
            "Transactions",
            "10/04/2026  BLUE BOTTLE COFFEE SAN FRANCISCO CA  2%  $0.14  $7.00",
            "10/11/2026  DELTA AIR LINES ATLANTA GA  2%  $8.40  $420.00",
            "Payments",
            "10/15/2026  ACH DEPOSIT INTERNET TRANSFER  $250.00",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        check(stmt.detectedIssuer == "Apple", "Apple issuer detected")
        check(stmt.detectedProductID == "apple-card", "Apple Card product detected (got \(stmt.detectedProductID ?? "nil"))")
        check(stmt.transactions.count == 3, "Apple Card parses 3 rows (got \(stmt.transactions.count))")
        if stmt.transactions.count == 3 {
            let coffee = stmt.transactions[0]
            check(coffee.amount == Money(700, .usd), "Coffee amount is $7.00 (not Daily Cash $0.14)")
            check(coffee.originalDescription == "BLUE BOTTLE COFFEE SAN FRANCISCO CA", "Daily Cash column stripped from description (got '\(coffee.originalDescription)')")
            check(coffee.category == .dining, "Blue Bottle is dining")

            let flight = stmt.transactions[1]
            check(flight.amount == Money(42000, .usd) && flight.category == .flights, "Delta Air Lines is $420 flights")

            let ach = stmt.transactions[2]
            check(ach.amount == Money(-25000, .usd) && ach.kind == .payment, "Apple Card ACH Deposit under Payments is negative .payment (got \(ach.amount.formatted), \(ach.kind.rawValue))")
        }
    }

    // 5. Wealthsimple Visa (CAD, YYYY-MM-DD dates)
    do {
        let pages: [[String]] = [[
            "Wealthsimple Visa Infinite Privilege",
            "Card Number: •••• •••• •••• 3319",
            "2026-10-01 to 2026-10-31",
            "TRANSACTIONS",
            "2026-10-05  SHOPPERS DRUG MART #0512 TORONTO ON  CA$34.50",
            "2026-10-12  AIR CANADA MONTREAL QC  612.80",
            "2026-10-20  PRESTO FARE TORONTO ON  3.30",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        check(stmt.detectedIssuer == "Wealthsimple", "Wealthsimple issuer detected")
        check(stmt.currency == .cad, "Wealthsimple currency is CAD")
        check(stmt.accountMask == "3319", "Wealthsimple mask is 3319")
        check(stmt.transactions.count == 3, "Wealthsimple parses 3 rows")
        if stmt.transactions.count == 3 {
            check(stmt.transactions[0].category == .drugstore && stmt.transactions[0].amount == Money(3450, .cad), "Shoppers Drug Mart CAD")
            check(stmt.transactions[1].category == .flights && stmt.transactions[1].amount == Money(61280, .cad), "Air Canada CAD")
            check(stmt.transactions[2].category == .transit && stmt.transactions[2].amount == Money(330, .cad), "PRESTO transit CAD")
        }
    }

    // 6. Cross-year wraparound (Dec 15, 2025 – Jan 14, 2026) + DD MMM two-date layout (must not eat day 28 as item#)
    do {
        let pages: [[String]] = [[
            "Chase Sapphire Reserve",
            "Opening/Closing Date 12/15/2025 - 01/14/2026",
            "ACCOUNT ACTIVITY",
            "Dec 28  Dec 29  UNITED AIRLINES HOUSTON TX  310.00",
            "Jan 03  Jan 04  UBER *TRIP SAN FRANCISCO CA  24.50",
            "28 Dec  29 Dec  WHOLE FOODS MARKET  84.10",
            "05 Jan  06 Jan  DISNEY+ STREAMING  15.99-",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: Day.make(2026, 2, 1))
        check(stmt.transactions.count == 4, "Cross-year parses 4 rows (got \(stmt.transactions.count))")
        if stmt.transactions.count == 4 {
            check(stmt.transactions[0].authorized == Day.make(2025, 12, 28) && stmt.transactions[0].posted == Day.make(2025, 12, 29),
                  "Dec 28/29 resolves to 2025 (got \(Day.key(stmt.transactions[0].posted)))")
            check(stmt.transactions[1].authorized == Day.make(2026, 1, 3) && stmt.transactions[1].posted == Day.make(2026, 1, 4),
                  "Jan 03/04 resolves to 2026 (got \(Day.key(stmt.transactions[1].posted)))")
            check(stmt.transactions[2].authorized == Day.make(2025, 12, 28) && stmt.transactions[2].posted == Day.make(2025, 12, 29),
                  "DD MMM two-date '28 Dec 29 Dec' must preserve day 28 (got \(Day.key(stmt.transactions[2].posted)))")
            check(stmt.transactions[3].posted == Day.make(2026, 1, 6) && stmt.transactions[3].amount == Money(-1599, .usd),
                  "Trailing minus '15.99-' parsed as negative on 2026-01-06")
        }
    }

    // 7. French Canadian statement dates & keywords
    do {
        let pages: [[String]] = [[
            "Banque Nationale Mastercard",
            "Statement Date: 2026-12-10",
            "20 nov.  METRO PLUS MONTREAL QC  72.15",
            "03 déc.  PAIEMENT MERCI  200.00",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: Day.make(2026, 12, 12))
        check(stmt.detectedIssuer == "National Bank", "Banque Nationale mapped to National Bank")
        check(stmt.currency == .cad, "National Bank currency is CAD")
        check(stmt.transactions.count == 2, "French dates parse 2 rows (got \(stmt.transactions.count))")
        if stmt.transactions.count == 2 {
            check(stmt.transactions[0].posted == Day.make(2026, 11, 20) && stmt.transactions[0].category == .groceries, "20 nov. Metro grocery")
            check(stmt.transactions[1].posted == Day.make(2026, 12, 3) && stmt.transactions[1].amount == Money(-20000, .cad) && stmt.transactions[1].kind == .payment,
                  "03 déc. PAIEMENT MERCI implicit negative payment")
        }
    }

    // 8. Deterministic sourceID, same-day occurrence disambiguation, and cross-source matchesExisting
    do {
        let pages: [[String]] = [[
            "American Express",
            "Statement Closing Date: 11/10/2026",
            "PURCHASES",
            "11/03/2026  STARBUCKS #1204 NEW YORK NY  $5.75",
            "11/03/2026  STARBUCKS #1204 NEW YORK NY  $5.75",
            "11/04/2026  RESY BISTRO NEW YORK NY  $48.00",
        ]]
        let s1 = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        let s2 = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        check(s1.transactions.count == 3, "Duplicate coffee test parses 3 rows")
        if s1.transactions.count == 3 && s2.transactions.count == 3 {
            let idA0 = PDFStatementParser.sourceID(cardID: "card-1", transaction: s1.transactions[0], occurrenceIndex: 0)
            let idA1 = PDFStatementParser.sourceID(cardID: "card-1", transaction: s1.transactions[1], occurrenceIndex: 1)
            let idB0 = PDFStatementParser.sourceID(cardID: "card-1", transaction: s2.transactions[0], occurrenceIndex: 0)
            check(idA0 == idB0, "Re-parsing the same statement yields identical sourceID")
            check(idA0 != idA1, "Two identical coffees on same day get distinct sourceIDs via occurrenceIndex")
            check(idA0.hasPrefix("pdf:card-1:2026-11-03:575:"), "sourceID format carries card, date, minor units")

            let existingPlaid = Transaction(
                id: "plaid-1", cardID: "card-1", amount: Money(4800, .usd), posted: Day.make(2026, 11, 5),
                authorized: Day.make(2026, 11, 4), merchant: "Resy Bistro", originalDescription: "TST* RESY BISTRO NYC",
                category: .dining, kind: .purchase, pending: false, provenance: .plaid
            )
            check(PDFStatementParser.matchesExisting(s1.transactions[2], existing: existingPlaid),
                  "Cross-source match within 1 day + same amount + shared token 'RESY'/'BISTRO'")

            let differentDate = Transaction(
                id: "plaid-2", cardID: "card-1", amount: Money(4800, .usd), posted: Day.make(2026, 11, 10),
                authorized: nil, merchant: "Resy Bistro", originalDescription: "RESY BISTRO",
                category: .dining, kind: .purchase, pending: false, provenance: .plaid
            )
            check(!PDFStatementParser.matchesExisting(s1.transactions[2], existing: differentDate),
                  "Row 6 days away must not match as duplicate")
        }
    }

    // 8b. Word-boundary category safety & NSF charge reversal under Payments section
    do {
        let pages: [[String]] = [[
            "Chase Sapphire Preferred",
            "Statement Closing Date: 11/14/2026",
            "PURCHASES",
            "11/02/2026  NEIGHBORHOOD MARKET #12  $42.00",
            "11/03/2026  LONDON BOOKSHOP GBP 20.00  $26.15",
            "11/04/2026  ZERO BALANCE CHECK  $0.00",
            "PAYMENTS AND CREDITS",
            "11/06/2026  NSF RETURNED PAYMENT  $125.00",
            "11/07/2026  ONLINE PAYMENT  $125.00",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        check(stmt.transactions.count == 4, "Word-boundary test parses 4 non-zero rows (got \(stmt.transactions.count))")
        if stmt.transactions.count == 4 {
            check(stmt.transactions[0].category == .other, "NEIGHBORHOOD must not match HBO streaming (got \(stmt.transactions[0].category.rawValue))")
            check(stmt.transactions[1].category == .other, "GBP must not match BP gas (got \(stmt.transactions[1].category.rawValue))")
            check(stmt.transactions[2].amount == Money(12500, .usd), "NSF RETURNED PAYMENT stays positive debit (+125.00, got \(stmt.transactions[2].amount.formatted))")
            check(stmt.transactions[3].amount == Money(-12500, .usd) && stmt.transactions[3].kind == .payment,
                  "ONLINE PAYMENT under PAYMENTS AND CREDITS is negative payment")
        }
    }

    // 9. BenefitEngine & WelcomeOfferEngine integration with PDF-imported transactions
    do {
        let card = Card(
            id: "amex-1", nickname: "Amex Gold", productID: "amex-gold-us", mask: "1008",
            openedOn: Day.make(2026, 10, 1), renewal: nil, connection: .pdf,
            lastSync: nil, historyStart: Day.make(2026, 10, 1)
        )
        let pages: [[String]] = [[
            "American Express Gold Card",
            "Account Ending 1008",
            "Statement Closing Date: 11/14/2026",
            "PURCHASES",
            "11/02/2026  DUNKIN #3021 BOSTON MA  $7.50",
            "11/04/2026  AMEX DUNKIN CREDIT  -$7.00",
            "11/06/2026  WHOLE FOODS MARKET BOSTON MA  $250.00",
        ]]
        let stmt = PDFStatementParser.parse(pages: pages, referenceToday: refToday)
        let ledgerTxns = stmt.transactions.map { t in
            Transaction(
                id: t.id, cardID: card.id, amount: t.amount, posted: t.posted, authorized: t.authorized,
                merchant: t.merchant, originalDescription: t.originalDescription, category: t.category,
                kind: t.kind, pending: false, provenance: .pdf
            )
        }
        let benefitResult = BenefitEngine.evaluate(cards: [card], transactions: ledgerTxns, decisions: [:], today: refToday)
        let dunkinPeriod = benefitResult.periods.first { $0.rule.id.contains("dunkin") && $0.isCurrent(today: refToday) }
        check(dunkinPeriod != nil, "Amex Gold Dunkin credit period exists")
        if let dunkinPeriod {
            check(dunkinPeriod.confirmed == Money(700, .usd), "PDF-imported Dunkin statement credit counts toward benefit ($7.00, got \(dunkinPeriod.confirmed.formatted))")
        }

        let offer = WelcomeOffer(
            id: "wo-1", cardID: card.id, kind: .spendBonus, currency: .usd,
            start: Day.make(2026, 10, 1), months: 6, minSpend: Money(600000, .usd),
            points: 60000, cash: nil, extraMultiplier: nil, categories: [], spendCap: nil, notes: "", markedEarned: false
        )
        let progress = WelcomeOfferEngine.progress(offer, transactions: ledgerTxns, today: refToday, cardCurrency: .usd)
        check(progress.spend == Money(25750, .usd), "PDF-imported purchases count toward welcome offer spend ($257.50, got \(progress.spend.formatted))")
    }

    // 10. Real PDFKit end-to-end extraction (multi-column CoreGraphics PDF + password protection + error cases)
    #if canImport(CoreGraphics) && canImport(CoreText) && canImport(PDFKit)
    do {
        // 10a. Unreadable data
        var gotUnreadable = false
        do { _ = try PDFStatementParser.parse(data: Data("not a pdf".utf8), referenceToday: refToday) }
        catch PDFStatementError.unreadablePDF { gotUnreadable = true }
        catch {}
        check(gotUnreadable, "Invalid bytes throw PDFStatementError.unreadablePDF")

        // 10b. Blank PDF (simulates scanned image with no text layer)
        let blankPDF = makeTestPDF(rows: [], password: nil)
        var gotNoText = false
        do { _ = try PDFStatementParser.parse(data: blankPDF, referenceToday: refToday) }
        catch PDFStatementError.noSelectableText { gotNoText = true }
        catch {}
        check(gotNoText, "Blank PDF with no selectable text throws PDFStatementError.noSelectableText")

        // 10c. Real multi-column PDF with separate X-coordinates per column
        let layoutRows: [[(x: CGFloat, text: String)]] = [
            [(x: 40, text: "Home Trust Preferred Visa")],
            [(x: 40, text: "Account Number: XXXX XXXX XXXX 5590"), (x: 360, text: "Statement Period: Oct 15, 2026 - Nov 14, 2026")],
            [(x: 40, text: "PURCHASES")],
            [(x: 40, text: "Oct 19"), (x: 105, text: "Oct 20"), (x: 175, text: "LOBLAWS #0811 TORONTO ON"), (x: 480, text: "$94.15")],
            [(x: 40, text: "Nov 01"), (x: 105, text: "Nov 02"), (x: 175, text: "SHELL CANADA TORONTO ON"), (x: 480, text: "$68.40")],
            [(x: 40, text: "PAYMENTS AND CREDITS")],
            [(x: 40, text: "Nov 05"), (x: 105, text: "Nov 06"), (x: 175, text: "PAYMENT - THANK YOU"), (x: 480, text: "$150.00")],
        ]
        let multiColPDF = makeTestPDF(rows: layoutRows, password: nil)
        let parsedPDF = try? PDFStatementParser.parse(data: multiColPDF, referenceToday: refToday)
        check(parsedPDF != nil, "Real PDFKit parse succeeds on multi-column PDF")
        if let parsedPDF {
            check(parsedPDF.detectedIssuer == "Home Trust", "PDFKit extracted issuer Home Trust")
            check(parsedPDF.accountMask == "5590", "PDFKit extracted mask 5590 (got \(parsedPDF.accountMask ?? "nil"))")
            check(parsedPDF.currency == .cad, "PDFKit extracted currency CAD")
            check(parsedPDF.transactions.count == 3, "PDFKit clustered 3 visual rows (got \(parsedPDF.transactions.count))")
            if parsedPDF.transactions.count == 3 {
                check(parsedPDF.transactions[0].amount == Money(9415, .cad) && parsedPDF.transactions[0].category == .groceries,
                      "Row 1 clustered correctly ($94.15 Loblaws)")
                check(parsedPDF.transactions[1].amount == Money(6840, .cad) && parsedPDF.transactions[1].category == .gas,
                      "Row 2 clustered correctly ($68.40 Shell)")
                check(parsedPDF.transactions[2].amount == Money(-15000, .cad) && parsedPDF.transactions[2].kind == .payment,
                      "Row 3 clustered correctly (-$150.00 Payment)")
            }
        }

        // 10d. Password-protected PDF
        let lockedPDF = makeTestPDF(rows: layoutRows, password: "secret-pass")
        var gotPasswordRequired = false
        do { _ = try PDFStatementParser.parse(data: lockedPDF, password: nil, referenceToday: refToday) }
        catch PDFStatementError.passwordRequired { gotPasswordRequired = true }
        catch {}
        check(gotPasswordRequired, "Locked PDF without password throws PDFStatementError.passwordRequired")

        var gotInvalidPassword = false
        do { _ = try PDFStatementParser.parse(data: lockedPDF, password: "wrong", referenceToday: refToday) }
        catch PDFStatementError.invalidPassword { gotInvalidPassword = true }
        catch {}
        check(gotInvalidPassword, "Locked PDF with wrong password throws PDFStatementError.invalidPassword")

        let unlocked = try? PDFStatementParser.parse(data: lockedPDF, password: "secret-pass", referenceToday: refToday)
        check(unlocked?.transactions.count == 3, "Locked PDF with correct password parses all 3 rows (got \(unlocked?.transactions.count ?? -1))")
    }
    #endif
}

#if canImport(CoreGraphics) && canImport(CoreText) && canImport(PDFKit)
private func makeTestPDF(rows: [[(x: CGFloat, text: String)]], password: String?) -> Data {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [:]
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password + "-owner"
    }
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info.isEmpty ? nil : (info as CFDictionary)) else {
        return Data()
    }
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]

    var y: CGFloat = 740
    for row in rows {
        for cell in row {
            let attrStr = NSAttributedString(string: cell.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.textPosition = CGPoint(x: cell.x, y: y)
            CTLineDraw(line, ctx)
        }
        y -= 20
    }
    ctx.endPDFPage()
    ctx.closePDF()
    return data as Data
}
#endif

@main
struct PDFStatementTestsMain {
    static func main() {
        runTests()
        print("PDFStatementTests: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
