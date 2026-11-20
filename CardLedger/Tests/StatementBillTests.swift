import XCTest
@testable import CardLedger

final class StatementBillTests: XCTestCase {
    func testPDFDueDateExtractionAcrossIssuerFormats() {
        let refToday = Day.make(2026, 11, 19)

        // 1. Amex Canada "Please pay by" + DD MMM YYYY
        let amexPages: [[String]] = [[
            "American Express Bank of Canada",
            "Opening Date  Closing Date",
            "Dec 17, 2025  Jan 16, 2026",
            "Please pay by 10 Feb 2026",
            "NEW TRANSACTIONS",
            "Dec 21  Dec 22  STARBUCKS TORONTO ON  $6.50",
        ]]
        let amex = PDFStatementParser.parse(pages: amexPages, referenceToday: refToday)
        XCTAssertEqual(amex.paymentDueDate, Day.make(2026, 2, 10))

        // 2. French Canadian statement ("Date d'échéance")
        let frenchPages: [[String]] = [[
            "Banque Nationale Mastercard",
            "Date du relevé : 2026-01-15",
            "Date d'échéance : 10 févr. 2026",
            "20 janv.  METRO PLUS MONTREAL QC  54.20",
        ]]
        let french = PDFStatementParser.parse(pages: frenchPages, referenceToday: refToday)
        XCTAssertEqual(french.paymentDueDate, Day.make(2026, 2, 10))

        // 3. Multi-column single line with both Closing Date and Payment Due Date
        let multiColPages: [[String]] = [[
            "Chase Sapphire Preferred",
            "Statement Closing Date: 11/14/2026   Payment Due Date: 12/09/2026",
            "PURCHASES",
            "11/02/2026  SWEETGREEN NEW YORK NY  $16.25",
        ]]
        let multiCol = PDFStatementParser.parse(pages: multiColPages, referenceToday: refToday)
        XCTAssertEqual(multiCol.statementClosingDate, Day.make(2026, 11, 14))
        XCTAssertEqual(multiCol.paymentDueDate, Day.make(2026, 12, 9))

        // 4. Stacked-header table (labels on row N, dates on row N+1)
        let stackedPages: [[String]] = [[
            "Capital One Venture X",
            "Statement Closing Date   Payment Due Date   Minimum Payment",
            "11/14/2026   12/09/2026   $35.00",
            "TRANSACTIONS",
            "11/05/2026  DELTA AIR LINES  $310.00",
        ]]
        let stacked = PDFStatementParser.parse(pages: stackedPages, referenceToday: refToday)
        XCTAssertEqual(stacked.paymentDueDate, Day.make(2026, 12, 9))

        // 5. Yearless due date across Dec -> Jan year boundary
        let crossYearPages: [[String]] = [[
            "Home Trust Preferred Visa",
            "Statement Date: Dec 18, 2025",
            "Payment Due Date: Jan 12",
            "PURCHASES",
            "Dec 10  Dec 11  LOBLAWS TORONTO ON  98.10",
        ]]
        let crossYear = PDFStatementParser.parse(pages: crossYearPages, referenceToday: Day.make(2025, 12, 20))
        XCTAssertEqual(crossYear.paymentDueDate, Day.make(2026, 1, 12))
    }

    func testMinimumPaymentDueIsNotTheDueDateLabel() {
        let refToday = Day.make(2026, 11, 19)
        let layouts: [[String]] = [
            ["Statement Date 11/14/2026", "New Balance $812.40", "Minimum Payment Due $25.00",
             "Statement closing date 11/14/2026", "Payment Due Date 12/09/2026"],
            ["New Balance as of Nov 14, 2026  Minimum Payment Due $25.00", "Payment Due Date: Dec 9, 2026"],
            ["Closing Date 11/14/2026", "Minimum Amount Due $35.00", "11/14/2026"],
        ]
        let expected: [Date?] = [Day.make(2026, 12, 9), Day.make(2026, 12, 9), nil]
        for (pages, want) in zip(layouts, expected) {
            XCTAssertEqual(PDFStatementParser.parse(pages: [pages], referenceToday: refToday).paymentDueDate, want, "\(pages)")
        }
    }

    func testCSVSlashDatesNeedAnUnambiguousOrder() {
        XCTAssertEqual(CSVStatementParser.parseFlexibleDate("12/25/2026"), Day.make(2026, 12, 25), "US month/day")
        XCTAssertEqual(CSVStatementParser.parseFlexibleDate("25/12/2026"), Day.make(2026, 12, 25), "Canadian day/month")
        XCTAssertNil(CSVStatementParser.parseFlexibleDate("05/12/2026"), "Ambiguous dates are left for the owner")
        XCTAssertEqual(CSVStatementParser.parseFlexibleDate("2026-12-09"), Day.make(2026, 12, 9))
        XCTAssertEqual(CSVStatementParser.parseFlexibleDate("9 Dec 2026"), Day.make(2026, 12, 9))
    }

    func testCSVDueDateExtractionWhenPresentAndNilWhenAbsent() throws {
        // 1. CSV with an optional Payment Due Date column picks the latest valid date.
        let csvWithDue = """
        Date,Date Processed,Description,Card Member,Account #,Amount,Additional Information,Reference,Payment Due Date
        01 Nov 2026,02 Nov 2026,LOBLAWS TORONTO ON,JANE DOE,-12345,45.20,,REF001,2026-11-28
        15 Nov 2026,16 Nov 2026,TIM HORTONS TORONTO ON,JANE DOE,-12345,5.50,,REF002,12 Dec 2026
        """
        let parsedWithDue = try CSVStatementParser.parse(text: csvWithDue)
        XCTAssertEqual(parsedWithDue.paymentDueDate, Day.make(2026, 12, 12))
        XCTAssertEqual(parsedWithDue.transactions.count, 2)

        // 2. Standard Amex Canada activity.csv without a due-date column still succeeds with nil paymentDueDate.
        let standardCSV = """
        Date,Date Processed,Description,Card Member,Account #,Amount,Additional Information,Reference
        15 Nov 2026,16 Nov 2026,TIM HORTONS TORONTO ON,JANE DOE,-12345,5.50,,REF003
        """
        let parsedStandard = try CSVStatementParser.parse(text: standardCSV)
        XCTAssertNil(parsedStandard.paymentDueDate)
        XCTAssertEqual(parsedStandard.transactions.count, 1)
    }

    func testStatementBillMergeProtectsNewerDatesAndPaidState() {
        let decBill = StatementBill(cardID: "c1", dueDate: Day.make(2026, 12, 10), source: .pdf, paidOn: Day.make(2026, 12, 1))

        // Importing an older statement must not overwrite a newer due date unless forceReplace is true.
        let olderNov = StatementBill(cardID: "c1", dueDate: Day.make(2026, 11, 10), source: .pdf)
        XCTAssertNil(olderNov.merged(over: decBill, forceReplace: false))
        XCTAssertEqual(olderNov.merged(over: decBill, forceReplace: true)?.dueDate, Day.make(2026, 11, 10))

        // Re-importing the same due date preserves paidOn status.
        let sameDec = StatementBill(cardID: "c1", dueDate: Day.make(2026, 12, 10), source: .pdf)
        let reimported = sameDec.merged(over: decBill, forceReplace: false)
        XCTAssertEqual(reimported?.isPaid, true)
        XCTAssertEqual(reimported?.paidOn, Day.make(2026, 12, 1))

        // Importing next month's statement resets paidOn for the new cycle.
        let janBill = StatementBill(cardID: "c1", dueDate: Day.make(2027, 1, 10), source: .pdf)
        let advanced = janBill.merged(over: decBill, forceReplace: false)
        XCTAssertEqual(advanced?.dueDate, Day.make(2027, 1, 10))
        XCTAssertEqual(advanced?.isPaid, false)
    }

    func testStatementBillAlertScheduleAndPlaidDeduplication() {
        let tz = TimeZone(identifier: "America/Toronto")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 8, minute: 0))!

        let unpaidPDF = StatementBill(cardID: "pdf-card", dueDate: Day.make(2026, 12, 10), source: .pdf)
        let paidPDF = StatementBill(cardID: "paid-card", dueDate: Day.make(2026, 12, 10), source: .pdf, paidOn: Day.make(2026, 12, 1))
        let plaidDup = StatementBill(cardID: "plaid-card", dueDate: Day.make(2026, 12, 12), source: .pdf)
        let plaidBills = [BillPayment(cardID: "plaid-card", dueDate: Day.make(2026, 12, 12))]

        let alerts = StatementBillAlertTime.upcoming(
            for: [unpaidPDF, paidPDF, plaidDup],
            excludingPlaidBills: plaidBills,
            after: now,
            timeZone: tz
        )

        XCTAssertEqual(alerts.count, 2, "Only the unpaid non-Plaid statement bill should schedule 2 reminders")
        XCTAssertEqual(alerts.map(\.cardID), ["pdf-card", "pdf-card"])
        XCTAssertEqual(alerts.map(\.dueThatDay), [false, true])
        XCTAssertEqual(alerts[0].components.day, 7)
        XCTAssertEqual(alerts[0].components.hour, 9)
        XCTAssertEqual(alerts[1].components.day, 10)
        XCTAssertEqual(alerts[1].components.hour, 9)
    }

    func testUpcomingCardBillMergeAndRepositoryPersistence() throws {
        let today = Day.make(2026, 12, 1)
        let plaid = [BillPayment(cardID: "c1", dueDate: Day.make(2026, 12, 8))]
        let statements = [
            StatementBill(cardID: "c1", dueDate: Day.make(2026, 12, 8), source: .pdf),
            StatementBill(cardID: "c2", dueDate: Day.make(2026, 12, 5), source: .pdf),
            StatementBill(cardID: "c3", dueDate: Day.make(2026, 12, 6), source: .csv, paidOn: Day.make(2026, 12, 1)),
            StatementBill(cardID: "deleted", dueDate: Day.make(2026, 12, 4), source: .pdf),
        ]

        let merged = UpcomingCardBill.merge(
            plaid: plaid,
            statement: statements,
            validCardIDs: ["c1", "c2", "c3"],
            today: today
        )
        XCTAssertEqual(merged.map(\.cardID), ["c2", "c1"], "Sorted soonest first, paid & deleted cards excluded, c1 deduplicated")
        XCTAssertEqual(merged[0].origin, .statement(.pdf))
        XCTAssertEqual(merged[1].origin, .plaid)

        // SQLCipher persistence round-trip
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = try EncryptedDatabase(directory: directory)
        let repo = try LedgerRepository(db: db)
        let bill = StatementBill(cardID: "card-abc", dueDate: Day.make(2026, 12, 15), statementDate: Day.make(2026, 11, 20), source: .pdf)
        try repo.saveStatementBill(bill, cardID: "card-abc")

        let loaded = try repo.statementBills()
        XCTAssertEqual(loaded["card-abc"]?.dueDate, Day.make(2026, 12, 15))
        XCTAssertEqual(loaded["card-abc"]?.statementDate, Day.make(2026, 11, 20))
        XCTAssertEqual(loaded["card-abc"]?.source, .pdf)

        try repo.saveStatementBill(nil, cardID: "card-abc")
        XCTAssertNil(try repo.statementBills()["card-abc"])
    }
}
