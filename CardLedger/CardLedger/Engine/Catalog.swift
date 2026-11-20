import Foundation

/// Bundled, versioned product catalog (design §4), decoded from Resources/catalog.json.
/// Source of truth: catalog-src/build_catalog.py. Values are unverified until checked against issuer terms.
enum Catalog {
    struct Bundle {
        let version: String
        let disclaimer: String
        let programs: [RewardProgram]
        let products: [CardProduct]
    }

    static let bundle: Bundle = load()

    static var version: String { bundle.version }
    static var disclaimer: String { bundle.disclaimer }
    static var programs: [RewardProgram] { bundle.programs }
    static var products: [CardProduct] { bundle.products }

    private static let byID: [String: CardProduct] = Dictionary(uniqueKeysWithValues: bundle.products.map { ($0.id, $0) })
    private static let programByID: [String: RewardProgram] = Dictionary(uniqueKeysWithValues: bundle.programs.map { ($0.id, $0) })

    /// Unknown IDs (e.g. a product removed from a later catalog) fall back to the generic card for safety.
    static func product(_ id: String) -> CardProduct {
        byID[id] ?? byID[id.hasSuffix("-ca") ? "custom-ca" : "custom-us"] ?? bundle.products[0]
    }

    static func exactProduct(_ id: String) -> CardProduct? { byID[id] }

    static func program(_ id: String) -> RewardProgram { programByID[id] ?? bundle.programs[0] }

    static func products(market: CurrencyCode?) -> [CardProduct] {
        products.filter { market == nil || $0.market == market }
    }

    /// Products grouped by issuer (generic "Other" last), for pickers.
    static func grouped(market: CurrencyCode?) -> [(issuer: String, products: [CardProduct])] {
        Dictionary(grouping: products(market: market), by: \.issuer)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { ($0.0 == "Other" ? 1 : 0, $0.0) < ($1.0 == "Other" ? 1 : 0, $1.0) }
    }

    /// Issuers available in a market, generic "Other" last.
    static func issuers(market: CurrencyCode?) -> [String] { grouped(market: market).map(\.issuer) }

    private static func issuerMatches(_ issuer: String, text: String) -> Bool {
        let i = normalize(issuer)
        guard !i.isEmpty, !text.isEmpty else { return false }
        return text.contains(i) || i.contains(text)
            || (i == "american express" && text.contains("amex"))
            || (i == "td" && text.hasPrefix("td"))
            || (i == "rbc" && text.contains("royal bank"))
            || (i == "bmo" && text.contains("bank of montreal"))
            || (i == "scotiabank" && text.contains("scotia"))
            || (i == "pc financial" && text.contains("president"))
            || (i == "u.s. bank" && text.contains("us bank"))
            || (i == "bank of america" && text.contains("bofa"))
    }

    /// Maps a bank/institution name from Plaid (e.g. "TD Canada Trust", "RBC Royal Bank") to a catalog issuer.
    static func issuer(matching institution: String?, market: CurrencyCode?) -> String? {
        guard let inst = institution.map(normalize), !inst.isEmpty else { return nil }
        return issuers(market: market).filter { $0 != "Other" }.first { issuerMatches($0, text: inst) }
    }

    /// Suggests a product for a linked account from its name, institution and currency. The owner confirms.
    static func suggest(accountName: String, institution: String?, currency: String?) -> CardProduct {
        let market = currency.flatMap(CurrencyCode.init(rawValue:))
        let name = normalize(accountName)
        let inst = normalize(institution ?? "")
        let candidates = products(market: market).filter { $0.issuer != "Other" }
        // The most specific keyword decides; a matching institution is a strong tie-breaker, but only
        // when the account name also matched a keyword, so an unknown card at a known bank stays "Other".
        func score(_ p: CardProduct) -> Int {
            let specificity = p.matchKeywords.filter { keyword in
                // Match complete terms so the ION and Avion families remain distinct.
                let literal = NSRegularExpression.escapedPattern(for: keyword)
                return name.range(of: "(?<![\\p{L}\\p{N}])\(literal)(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
            }.map(\.count).max() ?? 0
            guard specificity > 0 else { return 0 }
            let issuerMatch = (!inst.isEmpty && issuerMatches(p.issuer, text: inst)) || issuerMatches(p.issuer, text: name)
            return specificity + (issuerMatch ? 25 : 0)
        }
        let best = candidates.map { ($0, score($0)) }.max { $0.1 < $1.1 }
        if let best, best.1 > 0 { return best.0 }
        return product(market == .cad ? "custom-ca" : "custom-us")
    }

    /// Lower-cases and strips trademark symbols so "SkyMiles® Platinum" matches "skymiles platinum".
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[®™©*]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Decoding

    private struct FileDTO: Decodable {
        let version: String
        let disclaimer: String
        let programs: [ProgramDTO]
        let products: [ProductDTO]
    }
    private struct ProgramDTO: Decodable { let id, name, unit: String; let centsPerPoint: Double; let currency: CurrencyCode }
    private struct EarnDTO: Decodable {
        let categories: [RewardCategory]; let x: Double
        let cap: Double?; let capPeriod: PeriodKind?
        let merchants: [String]?; let restricted: Bool?; let note: String?
    }
    private struct BenefitDTO: Decodable {
        let id: String; let version: Int; let name: String; let cap: Double; let period: PeriodKind
        let descriptor: String; let lagDays: Int; let enrollment: Bool; let notes: String
        let merchants: [String]?; let categories: [RewardCategory]?
        let redeem: String?; let capByMonth: [String: Double]?; let certificate: CertificateDTO?
        let reviewOverlappingPeriods: Bool?
    }
    private struct CertificateDTO: Decodable {
        let trigger: String; let spend: Double?; let points: Int?; let label: String?; let validMonths: Int; let lagWeeks: Int
    }
    private struct StyleDTO: Decodable { let from, to: String; let lightText: Bool }
    private struct ProductDTO: Decodable {
        let id, issuer, name: String; let market: CurrencyCode; let network: String
        let annualFee, ftf: Double; let program: String; let base: Double
        let earn: [EarnDTO]; let benefits: [BenefitDTO]; let perks: [String]; let style: StyleDTO; let artCode: String
        let match: [String]; let source: String; let status: String; let checked: String?; let notes: String?
        let segment: String?
        let plaidSupport: PlaidSupport?
    }

    private static func load() -> Bundle {
        let url = Foundation.Bundle.main.url(forResource: "catalog", withExtension: "json")
            ?? ProcessInfo.processInfo.environment["CARD_LEDGER_CATALOG_PATH"].map { URL(fileURLWithPath: $0) }
        guard let url, let data = try? Data(contentsOf: url) else {
            fatalError("catalog.json is missing from the app bundle")
        }
        let file: FileDTO
        do { file = try JSONDecoder().decode(FileDTO.self, from: data) }
        catch { fatalError("catalog.json is invalid: \(error)") }

        let programs = file.programs.map {
            RewardProgram(id: $0.id, name: $0.name, unit: $0.unit, defaultCentsPerPoint: $0.centsPerPoint, currency: $0.currency)
        }
        let products = file.products.map { p in
            let source = URL(string: p.source)!
            return CardProduct(
                id: p.id, name: p.name, issuer: p.issuer, market: p.market, network: p.network,
                annualFee: .dollars(p.annualFee, p.market), foreignTransactionFee: p.ftf,
                programID: p.program, baseMultiplier: p.base,
                earnRules: p.earn.map {
                    EarnRule(Set($0.categories), $0.x, cap: $0.cap.map { Money.dollars($0, p.market) }, per: $0.capPeriod,
                             merchants: $0.merchants ?? [], channelRestricted: $0.restricted ?? false, note: $0.note)
                },
                benefits: p.benefits.map { b in
                    BenefitRule(id: b.id, version: b.version, name: b.name, cap: .dollars(b.cap, p.market), period: b.period,
                                merchantKeywords: b.merchants ?? [], eligibleCategories: Set(b.categories ?? []),
                                creditDescriptor: b.descriptor, creditLagDays: b.lagDays, requiresEnrollment: b.enrollment,
                                sourceURL: source, notes: b.notes,
                                redemption: BenefitRule.Redemption(rawValue: b.redeem ?? "statement") ?? .statementCredit,
                                capByMonth: Dictionary(uniqueKeysWithValues: (b.capByMonth ?? [:]).compactMap { k, v in
                                    Int(k).map { ($0, Money.dollars(v, p.market)) } }),
                                certificate: b.certificate.map { c in
                                    CertificateSpec(
                                        trigger: c.trigger == "spend" ? .calendarYearSpend(.dollars(c.spend ?? 0, p.market)) : .renewal,
                                        pointsCap: c.points, label: c.label, validMonths: c.validMonths, issueLagWeeks: c.lagWeeks)
                                }, reviewOverlappingPeriods: b.reviewOverlappingPeriods ?? false)
                },
                perks: p.perks,
                color: CardStyle(from: p.style.from, to: p.style.to, lightText: p.style.lightText),
                artCode: p.artCode,
                matchKeywords: p.match, sourceURL: source, verified: p.status == "verified", checkedOn: p.checked, notes: p.notes,
                isBusiness: p.segment == "business", plaidSupport: p.plaidSupport)
        }
        return Bundle(version: file.version, disclaimer: file.disclaimer, programs: programs, products: products)
    }
}
