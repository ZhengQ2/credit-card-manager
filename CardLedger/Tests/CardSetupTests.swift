import XCTest
@testable import CardLedger

final class CardSetupTests: XCTestCase {
    func testCatalogDecodesAuditedCoverageByMarket() {
        XCTAssertEqual(Catalog.exactProduct("capone-quicksilver")?.plaidSupport, .oauth)
        XCTAssertEqual(Catalog.exactProduct("capone-ca-platinum")?.plaidSupport, .limited)
        XCTAssertEqual(Catalog.exactProduct("amex-cobalt-ca")?.plaidSupport, .credential)
        XCTAssertNil(Catalog.exactProduct("custom-us")?.plaidSupport)

        let unsupported = Catalog.products.filter(\.suggestsStatementImport)
        XCTAssertEqual(Set(unsupported.map(\.id)), [
            "apple-card", "home-trust-preferred", "mbna-rewards-we", "mbna-true-line", "mbna-rewards-plat",
        ])
        XCTAssertEqual(Catalog.products.filter { $0.plaidSupport == .limited }.count, 18)
        XCTAssertTrue(Catalog.products.filter { $0.issuer != "Other" }.allSatisfy { $0.plaidSupport != nil })
    }
}
