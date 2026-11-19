import XCTest
@testable import CardLedger

/// American Express Canada activity CSV. All names, numbers and references are synthetic.
final class CSVStatementTests: XCTestCase {
    private let header = "Date,Date Processed,Description,Card Member,Account #,Amount,Foreign Spend Amount,Commission,Exchange Rate,Additional Information,Merchant,Address,City / Province,Postal Code,Country,Reference"

    private func row(_ date: String, _ processed: String, _ desc: String, _ account: String, _ amount: String,
                     info: String = "", address: String = "", ref: String) -> String {
        "\(date),\(processed),\(desc),JANE DOE,\(account),\(amount),,,,\(info),\(desc),\(address),\"TORONTO\nON\",M5V 0A1,CANADA,'\(ref)'"
    }

    private var sample: String {
        [header,
         row("17 Jan 2026", "18 Jan 2026", "NOODLE HOUSE          TORONTO", "-12345", "31.25", address: "1 KING ST W", ref: "R0001"),
         row("16 Jan 2026", "16 Jan 2026", "MEMBERSHIP FEE INSTALLMENT", "-12345", "15.99", ref: "R0002"),
         row("11 Jan 2026", "11 Jan 2026", "SANDWICH SHOP # 1001", "-12345", "-5.00", info: "ShopSmallOffer", ref: "R0003"),
         row("09 Jan 2026", "10 Jan 2026", "GROCERY DELIVERY", "-12345", "-10.00", info: "Grocery Offer", ref: "R0004"),
         row("05 Jan 2026", "05 Jan 2026", "PAYMENT RECEIVED - THANK YOU", "-12345", "\"-1,200.00\"", ref: "R0005"),
         row("04 Jan 2026", "05 Jan 2026", "STREAMCO.COM/BILL", "-12345", "-12.00", ref: "R0006"),
         row("03 Jan 2026", "04 Jan 2026", "\"CAFE \"\"TWO\"\" BEANS\"", "-12399", "4.50", ref: "R0007"),
         row("31 Dec 2025", "31 Dec 2025", "INTEREST", "-12345", "2.10", ref: "R0008"),
        ].joined(separator: "\r\n") + "\r\n"
    }

    func testAmexCanadaExport() throws {
        let stmt = try CSVStatementParser.parse(text: sample)
        XCTAssertEqual(stmt.transactions.count, 8)
        XCTAssertEqual(stmt.currency, .cad)
        XCTAssertEqual(stmt.detectedIssuer, "American Express")
        XCTAssertEqual(stmt.accountMask, "12345", "Most common account number is the card")
        XCTAssertEqual(stmt.warnings.count, 1, "Rows from an additional card on the account are called out")
        XCTAssertEqual(stmt.statementPeriodStart, Day.make(2025, 12, 31))
        XCTAssertEqual(stmt.statementPeriodEnd, Day.make(2026, 1, 18))

        let byRef = Dictionary(uniqueKeysWithValues: stmt.transactions.map { ($0.sourceKey ?? "", $0) })
        XCTAssertEqual(byRef.count, 8, "Each row keeps its issuer reference without quotes")

        let noodle = try XCTUnwrap(byRef["R0001"])
        XCTAssertEqual(noodle.kind, .purchase)
        XCTAssertEqual(noodle.amount, Money(3125, .cad))
        XCTAssertEqual(noodle.posted, Day.make(2026, 1, 18), "Posted is Date Processed")
        XCTAssertEqual(noodle.authorized, Day.make(2026, 1, 17), "Authorized is the transaction date")
        XCTAssertEqual(noodle.category, .dining)
        XCTAssertEqual(noodle.provenance, .csv)

        XCTAssertEqual(byRef["R0002"]?.kind, .fee, "Monthly fee instalment is a fee")
        XCTAssertEqual(byRef["R0003"]?.kind, .offerCredit)
        XCTAssertEqual(byRef["R0003"]?.offerTag, "ShopSmallOffer")
        XCTAssertEqual(byRef["R0004"]?.kind, .offerCredit, "\"Grocery Offer\" with a space is an offer label too")
        XCTAssertEqual(byRef["R0005"]?.kind, .payment)
        XCTAssertEqual(byRef["R0005"]?.amount, Money(-120000, .cad), "Thousands separators are handled")
        XCTAssertEqual(byRef["R0006"]?.kind, .refund, "A credit without an offer label is a merchant refund")
        XCTAssertEqual(byRef["R0007"]?.originalDescription, "CAFE \"TWO\" BEANS", "Doubled quotes unescape")
        XCTAssertEqual(byRef["R0008"]?.kind, .fee, "Interest is a fee")
    }

    func testSourceIDUsesIssuerReference() throws {
        let stmt = try CSVStatementParser.parse(text: sample)
        let t = try XCTUnwrap(stmt.transactions.first { $0.sourceKey == "R0003" })
        XCTAssertEqual(PDFStatementParser.sourceID(cardID: "card", transaction: t, occurrenceIndex: 3), "csv:card:R0003")
    }

    func testRejectsOtherLayouts() {
        XCTAssertThrowsError(try CSVStatementParser.parse(text: "Posted Date,Payee,Amount\n2026-01-01,SHOP,1.00\n")) {
            XCTAssertEqual($0 as? CSVStatementError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try CSVStatementParser.parse(text: header + "\n")) {
            XCTAssertEqual($0 as? CSVStatementError, .noRows)
        }
    }

    func testOfferTagRecognition() {
        for tag in ["ShopSmallOffer", "Grocery Offer", "CAFEOffer", "bookstoreOffer"] {
            XCTAssertTrue(PDFStatementParser.isOfferTag(tag), tag)
        }
        for text in ["ROUTING: FROM: N.Y. NEWARK", "Reference AT000000000000000000001", "UNITED STATES DOLLAR 199.94 1.44813 @",
                     "This is a very long sentence about an exclusive Offer"] {
            XCTAssertFalse(PDFStatementParser.isOfferTag(text), text)
        }
    }
}
