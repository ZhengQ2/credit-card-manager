import UniformTypeIdentifiers
import XCTest
@testable import CardLedger

final class OFXStatementTests: XCTestCase {
    func testStatementPickerIncludesBothExtensions() {
        XCTAssertTrue(StatementFileFormat.allCases.contains(.ofx))
        XCTAssertEqual(Set(StatementFileFormat.ofx.contentTypes.compactMap(\.preferredFilenameExtension)), ["ofx", "qfx"])
    }

    func testLegacyOFXWithUnclosedFieldsAndWindowsText() throws {
        let fixture = """
        OFXHEADER:100
        DATA:OFXSGML
        VERSION:102
        SECURITY:NONE
        ENCODING:USASCII
        CHARSET:1252

        <OFX><SIGNONMSGSRSV1><SONRS><FI><ORG>Example Bank<FID>demo-fi</FI></SONRS></SIGNONMSGSRSV1>
        <CREDITCARDMSGSRSV1><CCSTMTTRNRS><STATUS><CODE>0<SEVERITY>INFO</STATUS><CCSTMTRS>
        <CURDEF>CAD<CCACCTFROM><ACCTID>DEMO-0000</CCACCTFROM><BANKTRANLIST>
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261101<TRNAMT>-12,30<FITID>demo-a<NAME>Café & Books<MEMO></STMTTRN>
        <STMTTRN><TRNTYPE>PAYMENT<DTPOSTED>20261102<TRNAMT>+20.<FITID>demo-b<NAME>Card payment</STMTTRN>
        </BANKTRANLIST></CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>
        """
        let statement = try OFXStatementParser.parse(data: XCTUnwrap(fixture.data(using: .windowsCP1252)))

        XCTAssertEqual(statement.currency, .cad)
        XCTAssertEqual(statement.detectedIssuer, "Example Bank")
        XCTAssertEqual(statement.accountMask, "0000")
        XCTAssertEqual(statement.transactions.map(\.originalDescription), ["Café & Books", "Card payment"])
        XCTAssertEqual(statement.transactions.map(\.amount), [Money(1_230, .cad), Money(-2_000, .cad)])
        XCTAssertEqual(statement.transactions.map(\.kind), [.purchase, .payment])
        XCTAssertTrue(statement.transactions.allSatisfy { $0.provenance == .ofx })
        XCTAssertTrue(statement.warnings.isEmpty)
    }

    func testXMLQFXPreservesPrintedDayAndCurrency() throws {
        let data = xmlFile(rows: """
        <STMTTRN><TRNTYPE>INT</TRNTYPE><DTPOSTED>20261101235959.000[-5:EST]</DTPOSTED>
        <DTUSER>20261031</DTUSER><TRNAMT>-1.25000</TRNAMT><FITID>demo-fee</FITID>
        <NAME>Monthly fee &amp; interest</NAME></STMTTRN>
        <STMTTRN><TRNTYPE>CREDIT</TRNTYPE><DTPOSTED>20261102</DTPOSTED><TRNAMT>3.25</TRNAMT>
        <FITID>demo-refund</FITID><MEMO><![CDATA[Bookstore refund]]></MEMO></STMTTRN>
        """)
        let statement = try OFXStatementParser.parse(data: data)

        XCTAssertEqual(statement.transactions.map(\.posted), [Day.make(2026, 11, 1), Day.make(2026, 11, 2)])
        XCTAssertEqual(statement.transactions.first?.authorized, Day.make(2026, 10, 31))
        XCTAssertEqual(statement.transactions.map(\.amount), [Money(125, .usd), Money(-325, .usd)])
        XCTAssertEqual(statement.transactions.map(\.originalDescription), ["Monthly fee & interest", "Bookstore refund"])
        XCTAssertEqual(statement.transactions.first?.kind, .fee)
        XCTAssertNil(statement.statementClosingDate)
        XCTAssertNil(statement.paymentDueDate)
        XCTAssertNotNil(statement.statementPeriodEnd)
        XCTAssertNil(StatementFileFormat.ofx.reminderStatementDate(for: statement))
    }

    func testMalformedAndAmbiguousRowsAreReported() throws {
        let rows = [
            transaction("valid"),
            transaction("duplicate"), transaction("duplicate", amount: "-9.00"),
            transaction("ambiguous-date", date: "11/12/2026"),
            transaction("impossible-date", date: "20260230"),
            transaction("invalid-amount", amount: "-12.34garbage"),
            transaction("overflow", amount: "-9999999999999999999"),
            transaction("fraction-of-cent", amount: "-0.001"),
            transaction("conflicting-sign", amount: "+4.50"),
            transaction("corrected", extra: "<CORRECTFITID>obsolete</CORRECTFITID>"),
            transaction("other-currency", extra: "<CURRENCY><CURSYM>EUR</CURSYM></CURRENCY>"),
        ]
        let statement = try OFXStatementParser.parse(data: xmlFile(rows: rows.joined()))

        XCTAssertEqual(statement.transactions.count, 1)
        XCTAssertEqual(statement.warnings, ["Skipped 10 transaction rows with missing, ambiguous or unsupported fields."])
        XCTAssertThrowsError(try OFXStatementParser.parse(data: xmlFile(rows: transaction("id"), currency: "EUR"))) {
            XCTAssertEqual($0 as? OFXStatementError, .unsupportedCurrency)
        }
        XCTAssertThrowsError(try OFXStatementParser.parse(data: xmlFile(rows: transaction("id", date: "20260230")))) {
            XCTAssertEqual($0 as? OFXStatementError, .noUsableTransactions)
        }
    }

    func testMultipleCardStatementsAndMalformedXMLAreRejected() throws {
        let data = xmlFile(rows: transaction("id"))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let range = try XCTUnwrap(text.range(of: #"<CCSTMTTRNRS>[\s\S]*?</CCSTMTTRNRS>"#, options: .regularExpression))
        let twoStatements = text.replacingCharacters(in: range, with: String(text[range]) + String(text[range]))
        XCTAssertThrowsError(try OFXStatementParser.parse(data: Data(twoStatements.utf8))) {
            XCTAssertEqual($0 as? OFXStatementError, .multipleAccounts)
        }
        let malformed = text.replacingOccurrences(of: "</STMTTRN>", with: "")
        XCTAssertThrowsError(try OFXStatementParser.parse(data: Data(malformed.utf8))) {
            XCTAssertEqual($0 as? OFXStatementError, .unreadable)
        }
    }

    func testLedgerReimportUsesFITIDAndKeepsDistinctIdenticalCharges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(db: EncryptedDatabase(directory: directory))

        let first = try OFXStatementParser.parse(data: xmlFile(rows: transaction("original")))
        let cardID = try repo.createCardAndImportPDF(nickname: "Test card", productID: "custom-us", mask: nil,
                                                    openedOn: Day.make(2026, 1, 1), transactions: first.transactions).cardID
        XCTAssertEqual(try repo.cardIDForOFXAccount(XCTUnwrap(first.ofxAccountKey)), cardID)
        XCTAssertEqual(try repo.loadCards().first?.connection, .ofx)

        let second = try OFXStatementParser.parse(data: xmlFile(rows: transaction("original") + transaction("second")))
        let result = try repo.importPDFTransactions(second.transactions, cardID: cardID)
        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.skippedDuplicates, 1)

        let again = try repo.importPDFTransactions(second.transactions, cardID: cardID, skipMatchingExisting: false)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.skippedDuplicates, 2)
        XCTAssertEqual(try repo.loadTransactions().map(\.provenance), [.ofx, .ofx])
        XCTAssertEqual(try repo.existingPDFSourceIDs(cardID: cardID).count, 2)
    }

    private func xmlFile(rows: String, currency: String = "USD") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <?OFX OFXHEADER="200" VERSION="211" SECURITY="NONE"?>
        <OFX><CREDITCARDMSGSRSV1><CCSTMTTRNRS><STATUS><CODE>0</CODE></STATUS><CCSTMTRS>
        <CURDEF>\(currency)</CURDEF><CCACCTFROM><ACCTID>DEMO-ACCOUNT</ACCTID></CCACCTFROM>
        <BANKTRANLIST>\(rows)</BANKTRANLIST></CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>
        """.utf8)
    }

    private func transaction(_ reference: String, date: String = "20261101", amount: String = "-4.50", extra: String = "") -> String {
        """
        <STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>\(date)</DTPOSTED><TRNAMT>\(amount)</TRNAMT>
        <FITID>\(reference)</FITID><NAME>Bookstore</NAME>\(extra)</STMTTRN>
        """
    }
}
