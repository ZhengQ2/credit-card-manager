import XCTest
@testable import CardLedger

final class MCCCategoryTests: XCTestCase {
    private func makeRemote(
        id: String = "tx-1",
        name: String = "Merchant",
        originalDescription: String? = nil,
        primary: String? = nil,
        detailed: String? = nil,
        mcc: String? = nil
    ) -> RemoteTransaction {
        RemoteTransaction(
            id: id,
            accountId: "acct-1",
            amountMinor: 2500,
            currency: "USD",
            currencyIsOfficial: true,
            date: "2026-11-15",
            authorizedDate: nil,
            name: name,
            merchantName: name,
            originalDescription: originalDescription,
            categoryPrimary: primary,
            categoryDetailed: detailed,
            merchantCategoryCode: mcc,
            pending: false,
            pendingTransactionId: nil
        )
    }

    func testMCCDirectoryCoversAllSpecificCategoriesAndBoundaries() {
        let cases: [(Int, RewardCategory)] = [
            (3000, .flights),
            (3350, .flights),
            (4511, .flights),
            (3351, .carRental),
            (3500, .carRental),
            (7512, .carRental),
            (3501, .hotels),
            (3999, .hotels),
            (7011, .hotels),
            (4411, .travel),
            (4722, .travel),
            (4111, .transit),
            (4784, .transit),
            (7523, .transit),
            (5811, .dining),
            (5812, .dining),
            (5814, .dining),
            (5411, .groceries),
            (5499, .groceries),
            (5541, .gas),
            (5542, .gas),
            (5552, .evCharging),
            (5912, .drugstore),
            (4899, .streaming),
            (5815, .streaming),
            (5817, .streaming),
            (7832, .entertainment),
            (7996, .entertainment),
            (5300, .wholesale),
            (5200, .homeImprovement),
            (5251, .homeImprovement),
            (5712, .homeImprovement),
            (5310, .shopping),
            (5311, .shopping),
            (5732, .shopping),
            (5942, .shopping),
            (4814, .telecom),
            (4816, .telecom),
            (4900, .utilities),
            (7997, .fitness),
            (7298, .fitness),
            (8011, .healthcare),
            (8021, .healthcare),
            (8062, .healthcare),
            (5532, .auto),
            (7538, .auto),
            (7542, .auto),
            (5943, .office),
            (4215, .office),
            (7311, .office),
            (9402, .office),
            (6300, .insurance),
        ]

        var seen = Set<RewardCategory>()
        for (mcc, expected) in cases {
            XCTAssertEqual(MCCDirectory.category(for: mcc), expected, "MCC \(mcc) should map to \(expected.rawValue)")
            XCTAssertEqual(PlaidMapping.category(mcc: mcc), expected, "PlaidMapping.category(mcc: \(mcc)) should match")
            XCTAssertNotNil(MCCDirectory.description(for: mcc), "MCC \(mcc) should have a human-readable description")
            seen.insert(expected)
        }

        let allSpecific = Set(RewardCategory.allCases).subtracting([.other])
        XCTAssertEqual(seen, allSpecific, "Every non-other RewardCategory should have MCC mappings")
        XCTAssertNil(MCCDirectory.category(for: 9999))
    }

    func testMCCLabelsFormatCleanly() {
        XCTAssertEqual(MCCDirectory.label(for: "5411"), "5411 · Grocery Stores & Supermarkets")
        XCTAssertEqual(MCCDirectory.label(for: "5552"), "5552 · Electric Vehicle Charging")
        XCTAssertEqual(MCCDirectory.label(for: "5300"), "5300 · Wholesale Clubs")
        XCTAssertEqual(MCCDirectory.label(for: " 4814 "), "4814 · Telecommunication Services")
        XCTAssertEqual(MCCDirectory.label(for: "9999"), "9999")
    }

    func testPlaidMappingPrefersMCCAndFallsBackToPFC() {
        // MCC overrides a less-specific or differing Plaid PFC
        let evWithGasPFC = makeRemote(name: "Tesla Supercharger", primary: "TRANSPORTATION", detailed: "TRANSPORTATION_GAS", mcc: "5552")
        XCTAssertEqual(PlaidMapping.category(evWithGasPFC), .evCharging)

        let wholesaleWithSuperstorePFC = makeRemote(name: "Costco", primary: "GENERAL_MERCHANDISE", detailed: "GENERAL_MERCHANDISE_SUPERSTORES", mcc: "5300")
        XCTAssertEqual(PlaidMapping.category(wholesaleWithSuperstorePFC), .wholesale)

        // Wholesale heuristic when MCC is absent, without misclassifying Costco Gas
        let costcoNoMCC = makeRemote(name: "Costco", originalDescription: "COSTCO WHSE #0512", detailed: "GENERAL_MERCHANDISE_SUPERSTORES")
        XCTAssertEqual(PlaidMapping.category(costcoNoMCC), .wholesale)

        let costcoGasNoMCC = makeRemote(name: "Costco Gas", originalDescription: "COSTCO GAS #0512", detailed: "TRANSPORTATION_GAS")
        XCTAssertEqual(PlaidMapping.category(costcoGasNoMCC), .gas)

        // Plaid PFC detailed fallbacks when MCC is nil
        let pfcCases: [(String, RewardCategory)] = [
            ("TRAVEL_RENTAL_CARS", .carRental),
            ("TRAVEL_OTHER_TRAVEL", .travel),
            ("TRANSPORTATION_EV_CHARGING", .evCharging),
            ("TRANSPORTATION_PARKING", .transit),
            ("TRANSPORTATION_TOLLS", .transit),
            ("HOME_IMPROVEMENT_HARDWARE", .homeImprovement),
            ("GENERAL_MERCHANDISE_CLOTHING_AND_ACCESSORIES", .shopping),
            ("GENERAL_MERCHANDISE_OFFICE_SUPPLIES", .office),
            ("GENERAL_SERVICES_POSTAGE_AND_SHIPPING", .office),
            ("RENT_AND_UTILITIES_INTERNET_AND_CABLE", .telecom),
            ("RENT_AND_UTILITIES_TELEPHONE", .telecom),
            ("RENT_AND_UTILITIES_GAS_AND_ELECTRICITY", .utilities),
            ("PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS", .fitness),
            ("MEDICAL_DENTAL_CARE", .healthcare),
            ("MEDICAL_PHARMACIES_AND_SUPPLEMENTS", .drugstore),
            ("GENERAL_SERVICES_AUTOMOTIVE", .auto),
            ("GENERAL_SERVICES_INSURANCE", .insurance),
        ]
        for (detailed, expected) in pfcCases {
            let tx = makeRemote(detailed: detailed)
            XCTAssertEqual(PlaidMapping.category(tx), expected, "PFC \(detailed) should map to \(expected.rawValue)")
        }
    }

    func testStatementParserClassifiesExpandedCategories() {
        let samples: [(String, RewardCategory)] = [
            ("TESLA SUPERCHARGER TORONTO ON", .evCharging),
            ("SHELL RECHARGE SAN JOSE CA", .evCharging),
            ("COSTCO GAS #1042 TORONTO ON", .gas),
            ("COSTCO PHARMACY #1042 TORONTO ON", .drugstore),
            ("COSTCO WHOLESALE #1042 TORONTO ON", .wholesale),
            ("HERTZ RENT A CAR LAX CA", .carRental),
            ("EXPEDIA.COM SEATTLE WA", .travel),
            ("TELUS MOBILITY VANCOUVER BC", .telecom),
            ("TORONTO HYDRO TORONTO ON", .utilities),
            ("HOME DEPOT #7012 TORONTO ON", .homeImprovement),
            ("EQUINOX FITNESS NEW YORK NY", .fitness),
            ("DOWNTOWN DENTAL CLINIC TORONTO ON", .healthcare),
            ("JIFFY LUBE #221 AUSTIN TX", .auto),
            ("STAPLES #0118 TORONTO ON", .office),
            ("FEDEX SHIPPING MEMPHIS TN", .office),
            ("GEICO AUTO INSURANCE", .insurance),
            ("AMAZON.COM SEATTLE WA", .shopping),
            ("APPLE STORE FIFTH AVENUE NY", .shopping),
            ("APPLE.COM/BILL CUPERTINO CA", .streaming),
        ]
        for (desc, expected) in samples {
            let result = PDFStatementParser.classifyRow(description: desc, amountMinor: 4200)
            XCTAssertEqual(result.category, expected, "Description '\(desc)' should classify as \(expected.rawValue) (got \(result.category.rawValue))")
        }
    }

    func testCatalogEarnRulesMatchExpandedCategories() {
        let today = Day.make(2026, 11, 19)
        let assumptions = Assumptions()

        func card(_ id: String, _ productID: String) -> Card {
            Card(id: id, nickname: productID, productID: productID, mask: "1234",
                 openedOn: Day.make(2025, 1, 1), renewal: nil, connection: .manual,
                 lastSync: nil, historyStart: Day.make(2025, 1, 1))
        }

        let citiCostco = card("c1", "citi-costco-anywhere")
        let bofaCC = card("c2", "bofa-customized-cash")
        let wfAutograph = card("c3", "wf-autograph")
        let scotiaMom = card("c4", "scotia-momentum-vi")
        let csp = card("c5", "chase-sapphire-preferred")
        let hyatt = card("c6", "chase-world-of-hyatt")
        let inkCash = card("c7", "chase-ink-cash")
        let bbp = card("c8", "amex-blue-business-plus")
        let primeVisa = card("c9", "chase-amazon-prime-visa")

        let engine = RewardsEngine(
            cards: [citiCostco, bofaCC, wfAutograph, scotiaMom, csp, hyatt, inkCash, bbp, primeVisa],
            assumptions: assumptions
        )

        XCTAssertEqual(engine.quote(card: citiCostco, amount: .dollars(100, .usd), category: .evCharging, merchant: "Tesla Supercharger", date: today, usage: [:]).multiplier, 4)
        XCTAssertEqual(engine.quote(card: citiCostco, amount: .dollars(100, .usd), category: .wholesale, merchant: "Costco", date: today, usage: [:]).multiplier, 2)
        XCTAssertEqual(engine.quote(card: bofaCC, amount: .dollars(100, .usd), category: .wholesale, merchant: nil, date: today, usage: [:]).multiplier, 2)
        XCTAssertEqual(engine.quote(card: wfAutograph, amount: .dollars(100, .usd), category: .telecom, merchant: nil, date: today, usage: [:]).multiplier, 3)
        XCTAssertEqual(engine.quote(card: scotiaMom, amount: .dollars(100, .cad), category: .utilities, merchant: nil, date: today, usage: [:]).multiplier, 4)
        XCTAssertEqual(engine.quote(card: scotiaMom, amount: .dollars(100, .cad), category: .telecom, merchant: nil, date: today, usage: [:]).multiplier, 4)
        XCTAssertEqual(engine.quote(card: csp, amount: .dollars(100, .usd), category: .carRental, merchant: nil, date: today, usage: [:]).multiplier, 2)
        XCTAssertEqual(engine.quote(card: csp, amount: .dollars(100, .usd), category: .travel, merchant: nil, date: today, usage: [:]).multiplier, 2)
        XCTAssertEqual(engine.quote(card: hyatt, amount: .dollars(100, .usd), category: .fitness, merchant: nil, date: today, usage: [:]).multiplier, 2)
        XCTAssertEqual(engine.quote(card: inkCash, amount: .dollars(100, .usd), category: .office, merchant: nil, date: today, usage: [:]).multiplier, 5)
        XCTAssertEqual(engine.quote(card: inkCash, amount: .dollars(100, .usd), category: .telecom, merchant: nil, date: today, usage: [:]).multiplier, 5)
        XCTAssertEqual(engine.quote(card: bbp, amount: .dollars(100, .usd), category: .shopping, merchant: nil, date: today, usage: [:]).multiplier, 2)
        XCTAssertEqual(engine.quote(card: primeVisa, amount: .dollars(100, .usd), category: .shopping, merchant: "Amazon", date: today, usage: [:]).multiplier, 5)
    }

    func testMigrationV11BackfillsCategoriesFromStoredMCC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = try EncryptedDatabase(directory: directory)
        let repo = try LedgerRepository(db: db)
        try repo.createManualCard(nickname: "Sapphire", productID: "chase-sapphire-preferred", mask: "1234",
                                  openedOn: Day.make(2026, 1, 1), renewal: nil)
        let card = try XCTUnwrap(repo.loadCards().first)

        let seeded: [(id: String, merchant: String, mcc: String?, expected: RewardCategory)] = [
            ("ev", "Tesla Supercharger", "5552", .evCharging),
            ("club", "Costco", "5300", .wholesale),
            ("home", "Home Depot", "5200", .homeImprovement),
            ("tel", "Verizon", "4814", .telecom),
            ("util", "Con Edison", "4900", .utilities),
            ("health", "City Dental", "8021", .healthcare),
            ("fit", "Equinox", "7997", .fitness),
            ("car", "Hertz", "7512", .carRental),
            ("ins", "Geico", "6300", .insurance),
            ("off", "Staples", "5943", .office),
            ("none", "Local Shop", nil, .other),
        ]

        for row in seeded {
            try db.run("""
                INSERT INTO txn(id, card_id, provenance, source_id, amount_minor, currency, posted, merchant,
                                original_description, category, kind, pending, mcc)
                VALUES(?, ?, 'Plaid', ?, 5000, 'USD', '2026-11-10', ?, ?, 'other', 'purchase', 0, ?)
                """, [row.id.sql, card.id.sql, "plaid:\(row.id)".sql, row.merchant.sql, row.merchant.sql, row.mcc.sql])
        }
        // Save an owner override to make sure migration v11 leaves owner overrides untouched.
        try repo.saveCategoryOverride("club", .groceries)

        try db.setUserVersion(10)
        let migratedRepo = try LedgerRepository(db: db)
        let txns = Dictionary(uniqueKeysWithValues: try migratedRepo.loadTransactions().map { ($0.id, $0) })
        let overrides = try migratedRepo.categoryOverrides()

        for row in seeded {
            let loaded = try XCTUnwrap(txns[row.id])
            XCTAssertEqual(loaded.category, row.expected, "Row '\(row.id)' (MCC \(row.mcc ?? "nil")) should migrate to \(row.expected.rawValue)")
            XCTAssertEqual(loaded.mcc, row.mcc, "Row '\(row.id)' should load its stored MCC")
        }
        XCTAssertEqual(overrides["club"], .groceries, "Owner category override must survive migration v11")
    }
}
