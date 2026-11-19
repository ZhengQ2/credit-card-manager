import Foundation

/// Synthetic wallet and ledger, generated relative to today so the prototype always has live deadlines.
/// No real cardholder data. Dates after today are dropped.
enum SampleData {
    static func cards(today: Date) -> [Card] {
        let syncedRecently = Date().addingTimeInterval(-60 * 42)
        return [
            Card(id: "plat", nickname: "Platinum", productID: "amex-platinum-us", mask: "1008",
                 openedOn: Day.addMonths(-20, to: today), renewal: nil,
                 connection: .plaid(institution: "American Express"), lastSync: syncedRecently,
                 historyStart: Day.addMonths(-4, to: Day.startOfMonth(today))),
            Card(id: "aspire", nickname: "Aspire", productID: "amex-hilton-aspire", mask: "2004",
                 openedOn: Day.addMonths(-31, to: today),
                 renewal: RenewalDate(date: Day.addMonths(12, to: Day.add(2, to: Day.addMonths(-1, to: Day.startOfMonth(today)))), precision: .day, source: .owner),
                 connection: .plaid(institution: "American Express"), lastSync: syncedRecently,
                 historyStart: Day.addMonths(-4, to: Day.startOfMonth(today))),
            Card(id: "brilliant", nickname: "Brilliant", productID: "amex-marriott-brilliant", mask: "3002",
                 openedOn: Day.addMonths(-14, to: today), renewal: nil,
                 connection: .plaid(institution: "American Express"), lastSync: syncedRecently,
                 historyStart: Day.addMonths(-4, to: Day.startOfMonth(today))),
            Card(id: "cobalt", nickname: "Cobalt", productID: "amex-cobalt-ca", mask: "4001",
                 openedOn: Day.addMonths(-40, to: today), renewal: nil,
                 connection: .csv, lastSync: Date().addingTimeInterval(-60 * 60 * 24 * 3),
                 historyStart: Day.addMonths(-4, to: Day.startOfMonth(today))),
            Card(id: "aventura", nickname: "Aventura", productID: "cibc-aventura-vi", mask: "5003",
                 openedOn: Day.addMonths(-9, to: today),
                 renewal: RenewalDate(date: Day.addMonths(12, to: Day.addMonths(-3, to: Day.startOfMonth(today))), precision: .month, source: .inferredFromFee),
                 connection: .reauthRequired(institution: "CIBC"), lastSync: Date().addingTimeInterval(-60 * 60 * 24 * 6),
                 historyStart: Day.addMonths(-3, to: Day.startOfMonth(today))),
        ]
    }

    static func transactions(today: Date) -> [Transaction] {
        var b = Builder(today: today)
        let m0 = Day.startOfMonth(today)
        func month(_ offset: Int, _ day: Int) -> Date { Day.add(day - 1, to: Day.addMonths(offset, to: m0)) }
        let qStart = PeriodKind.quarterly.start(containing: today)
        let prevQ = Day.addMonths(-3, to: qStart)

        // ---- Platinum (USD) — digital entertainment credit
        for k in [-3, -2] {
            b.add("plat", 13.99, .usd, month(k, 5), "Disney+", "DISNEY PLUS BURBANK CA", .streaming)
            b.add("plat", -13.99, .usd, month(k, 7), "American Express", "PLATINUM DIGITAL ENTERTAINMENT CREDIT", .other, .issuerCredit)
            b.add("plat", 6.25, .usd, month(k, 12), "New York Times", "NYTIMES*NYTIMES DIGITAL", .streaming)
            b.add("plat", -6.25, .usd, month(k, 14), "American Express", "PLATINUM DIGITAL ENTERTAINMENT CREDIT", .other, .issuerCredit)
        }
        // Purchase on the last days of last month, credit posts on the 2nd: belongs to last month.
        b.add("plat", 13.99, .usd, Day.add(-2, to: m0), "Disney+", "DISNEY PLUS BURBANK CA", .streaming)
        b.add("plat", -13.99, .usd, month(0, 2), "American Express", "PLATINUM DIGITAL ENTERTAINMENT CREDIT", .other, .issuerCredit)
        b.add("plat", 10.99, .usd, month(0, 3), "Peacock", "PEACOCK PREMIUM NEW YORK NY", .streaming)
        b.add("plat", -10.99, .usd, month(0, 5), "American Express", "PLATINUM DIGITAL ENTERTAINMENT CREDIT", .other, .issuerCredit)
        b.add("plat", 13.99, .usd, month(0, 8), "YouTube Premium", "GOOGLE *YOUTUBEPREMIUM", .streaming)
        // Ambiguous credit: generic descriptor, goes to review.
        b.add("plat", -11.00, .usd, month(0, 9), "American Express", "AMEX STATEMENT CREDIT ADJUSTMENT", .other, .issuerCredit)
        b.add("plat", 642.30, .usd, month(-2, 9), "Delta Air Lines", "DELTA AIR LINES ATLANTA GA", .flights)
        b.add("plat", 488.10, .usd, month(-1, 21), "United Airlines", "UNITED 0162334455 HOUSTON TX", .flights)
        b.add("plat", 129.99, .usd, month(-1, 4), "Amazon", "AMZN MKTP US", .other)
        b.add("plat", -129.99, .usd, month(-1, 11), "Amazon", "AMZN MKTP US RETURN", .other, .refund)
        b.add("plat", 41.20, .usd, month(0, 7), "Uber", "UBER *TRIP", .transit)
        b.add("plat", 895.00, .usd, month(-2, 1), "American Express", "ANNUAL MEMBERSHIP FEE", .other, .fee)
        b.add("plat", -1500.00, .usd, month(-1, 25), "Payment", "PAYMENT RECEIVED - THANK YOU", .other, .payment)

        // ---- Aspire (USD) — flight credit per quarter, resort credit per half
        b.add("aspire", 412.00, .usd, Day.add(19, to: prevQ), "Air Canada", "AIR CANADA 0142233 MONTREAL", .flights)
        b.add("aspire", -50.00, .usd, Day.add(22, to: prevQ), "American Express", "HILTON ASPIRE FLIGHT CREDIT", .other, .issuerCredit)
        b.add("aspire", 289.40, .usd, Day.add(6, to: qStart), "United Airlines", "UNITED 0162298811 HOUSTON TX", .flights)
        b.add("aspire", -50.00, .usd, Day.add(9, to: qStart), "American Express", "HILTON ASPIRE FLIGHT CREDIT", .other, .issuerCredit)
        b.add("aspire", 66.80, .usd, month(-1, 13), "Carbone", "CARBONE NEW YORK NY", .dining)
        b.add("aspire", 310.55, .usd, month(-2, 17), "Hilton Chicago", "HILTON HOTELS CHICAGO IL", .hotels)
        b.add("aspire", 550.00, .usd, month(-1, 3), "American Express", "ANNUAL MEMBERSHIP FEE", .other, .fee)

        // ---- Brilliant (USD) — dining credit per month
        let restaurants = [("Sushi Nakazawa", 84.20), ("Via Carota", 61.75), ("Le Bernardin", 120.00)]
        for (i, k) in [-3, -2, -1].enumerated() {
            let r = restaurants[i]
            b.add("brilliant", r.1, .usd, month(k, 10), r.0, "\(r.0.uppercased()) NEW YORK NY", .dining)
            b.add("brilliant", -25.00, .usd, month(k, 12), "American Express", "BRILLIANT DINING CREDIT", .other, .issuerCredit)
        }
        b.add("brilliant", -20.00, .usd, month(-1, 17), "Le Bernardin", "LE BERNARDIN REFUND", .dining, .refund)
        b.add("brilliant", 18.40, .usd, month(0, 6), "Joe's Pizza", "JOES PIZZA BROADWAY NY", .dining)
        b.add("brilliant", 512.00, .usd, month(-1, 19), "Marriott Marquis", "MARRIOTT MARQUIS NEW YORK", .hotels)
        b.add("brilliant", 24.10, .usd, month(0, 15), "Blue Bottle", "BLUE BOTTLE COFFEE", .dining, pending: true)

        // ---- Cobalt (CAD, CSV) — groceries + eats
        let grocers = ["Loblaws", "Metro", "Sobeys", "T&T Supermarket"]
        let diners = ["Pai Northern Thai", "Uber Eats", "Bar Raval", "Tim Hortons"]
        for k in -3...0 {
            for w in 0..<4 {
                let day = 2 + w * 7
                b.add("cobalt", 92 + Double((w * 37 + k * 11 + 400) % 90), .cad, month(k, day), grocers[w], "\(grocers[w].uppercased()) #1\(w)2 TORONTO ON", .groceries, provenance: .csv)
                b.add("cobalt", 28 + Double((w * 23 + k * 7 + 300) % 60), .cad, month(k, day + 3), diners[w], "\(diners[w].uppercased()) TORONTO ON", .dining, provenance: .csv)
            }
            b.add("cobalt", 18.99, .cad, month(k, 11), "Netflix", "NETFLIX.COM", .streaming, provenance: .csv)
        }

        // ---- Aventura (CAD) — gas, drugstore, airfare
        for k in -2...0 {
            b.add("aventura", 71.40, .cad, month(k, 4), "Petro-Canada", "PETRO-CANADA 4410", .gas)
            b.add("aventura", 64.15, .cad, month(k, 16), "Shell", "SHELL C02455", .gas)
            b.add("aventura", 38.60, .cad, month(k, 8), "Shoppers Drug Mart", "SHOPPERS DRUG MART #0821", .drugstore)
        }
        b.add("aventura", 642.88, .cad, month(-2, 22), "Air Canada", "AIR CANADA 0142998 MONTREAL", .flights)
        b.add("aventura", 318.40, .cad, month(-1, 6), "WestJet", "WESTJET 8381992 CALGARY", .flights)
        b.add("aventura", 139.00, .cad, month(-3, 2), "CIBC", "ANNUAL FEE", .other, .fee)
        b.add("aventura", -900.00, .cad, month(-1, 28), "Payment", "PAYMENT THANK YOU / PAIEMENT MERCI", .other, .payment)

        return b.items.filter { $0.posted <= today }.sorted { $0.posted > $1.posted }
    }

    struct Builder {
        let today: Date
        var items: [Transaction] = []
        var n = 0

        mutating func add(_ card: String, _ amount: Double, _ currency: CurrencyCode, _ date: Date,
                          _ merchant: String, _ description: String, _ category: RewardCategory,
                          _ kind: TransactionKind = .purchase, pending: Bool = false, provenance: Provenance = .plaid) {
            n += 1
            items.append(Transaction(
                id: "tx-\(n)", cardID: card, amount: .dollars(amount, currency), posted: date,
                authorized: kind == .purchase ? Day.add(-1, to: date) : nil,
                merchant: merchant, originalDescription: description, category: category, kind: kind,
                pending: pending, provenance: provenance))
        }
    }
}
