import Foundation
import Observation
import UIKit

/// App state. Live data comes from the SQLCipher ledger; with no linked cards the app shows synthetic sample data.
@Observable
@MainActor
final class Store {
    enum DataMode: Equatable { case sample, live }

    var today: Date
    var cards: [Card] = []
    var transactions: [Transaction] = []
    var decisions: [String: ReviewDecision] = [:]
    var assumptions = Assumptions()
    var pinnedCard: [RewardCategory: String] = [:]
    var categoryOverrides: [String: RewardCategory] = [:]
    var reminderOffsets: Set<Int> = [7, 2]
    var isSyncing = false
    var lastSync: Date?
    var mode: DataMode = .sample
    var storageError: String?
    var syncMessage: String?
    var unknownCurrencyCount = 0
    var requireDeviceAuth = false

    // Owner service and Plaid
    let client = ServiceClient()
    private(set) var repo: LedgerRepository?
    private var engine: SyncEngine?
    /// Mirrors the Keychain pairing so views observe changes.
    private(set) var pairing: PairingConfig?
    var isPaired: Bool { pairing != nil }
    var serviceEnvironment: String? { pairing?.environment }
    /// Connections whose credit-card accounts still need to be mapped to cards.
    var pendingMappingConnectionID: String?
    /// Set when a card needs Plaid Link update mode.
    var reauthConnectionID: String?

    // Cross-tab navigation
    var selectedTab: Tab = .overview
    var activityCategory: RewardCategory?
    var activityCardID: String?

    enum Tab: Hashable { case overview, cards, activity, spending, bestCard }

    private(set) var benefits = BenefitResult()

    init(today: Date = Day.today) {
        self.today = today
        // Keychain entries outlive an uninstall; the data container does not. Start clean on a fresh install.
        if !UserDefaults.standard.bool(forKey: "installed.v1") {
            Keychain.delete(.serviceCredential)
            Keychain.delete(.databaseKey)
            client.unpair()
            UserDefaults.standard.set(true, forKey: "installed.v1")
        }
        pairing = client.pairing
        do {
            let db = try EncryptedDatabase()
            let repo = try LedgerRepository(db: db)
            self.repo = repo
            self.engine = SyncEngine(client: client, repo: repo)
            requireDeviceAuth = repo.setting("require_device_auth") == "1"
        } catch {
            storageError = error.localizedDescription
        }
        reload()
    }

    /// Loads the ledger from the encrypted store, or sample data when nothing is linked yet.
    func reload() {
        today = Day.today
        if let repo, let liveCards = try? repo.loadCards(), !liveCards.isEmpty {
            mode = .live
            cards = liveCards
            transactions = (try? repo.loadTransactions()) ?? []
            decisions = (try? repo.decisions()) ?? [:]
            categoryOverrides = (try? repo.categoryOverrides()) ?? [:]
            unknownCurrencyCount = (try? repo.unknownCurrencyCount()) ?? 0
            welcomeOffers = (try? repo.welcomeOffers()) ?? []
            usageLogs = (try? repo.usageLogs()) ?? []
            certificates = (try? repo.certificates()) ?? []
            lastSync = cards.compactMap(\.lastSync).max()
        } else {
            mode = .sample
            cards = SampleData.cards(today: today)
            transactions = SampleData.transactions(today: today)
            lastSync = Date().addingTimeInterval(-60 * 42)
            unknownCurrencyCount = 0
            welcomeOffers = []
            usageLogs = []
            certificates = []
        }
        recompute()
    }

    func recompute() {
        let usage = Dictionary(grouping: usageLogs, by: \.periodID).mapValues { $0.reduce(0) { $0 + $1.amount.minor } }
        benefits = BenefitEngine.evaluate(cards: cards, transactions: effectiveTransactions, decisions: decisions, today: today,
                                          usage: usage)
    }

    /// Transactions with owner category edits applied (kept across re-syncs, design §9).
    var effectiveTransactions: [Transaction] {
        transactions.map { t in
            guard let c = categoryOverrides[t.id] else { return t }
            return Transaction(id: t.id, cardID: t.cardID, amount: t.amount, posted: t.posted, authorized: t.authorized,
                               merchant: t.merchant, originalDescription: t.originalDescription, category: c, kind: t.kind,
                               pending: t.pending, provenance: t.provenance)
        }
    }

    var rewards: RewardsEngine { RewardsEngine(cards: cards, assumptions: assumptions) }

    func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    func transaction(_ id: String) -> Transaction? { effectiveTransactions.first { $0.id == id } }

    var openReviews: [ReviewItem] { benefits.reviews }

    var activeDeadlines: [BenefitPeriod] {
        benefits.periods.filter { $0.isCurrent(today: today) && $0.remaining.minor > 0 }
            .sorted { $0.end < $1.end }
    }

    // MARK: - Owner decisions (persisted for live data)

    func decide(_ creditID: String, _ decision: ReviewDecision) {
        decisions[creditID] = decision
        if mode == .live { try? repo?.saveDecision(creditID, decision) }
        recompute()
    }

    func undoDecision(_ creditID: String) {
        decisions[creditID] = nil
        if mode == .live { try? repo?.saveDecision(creditID, nil) }
        recompute()
    }

    func setCategory(_ category: RewardCategory, for transactionID: String) {
        categoryOverrides[transactionID] = category
        if mode == .live { try? repo?.saveCategoryOverride(transactionID, category) }
        recompute()
    }

    func setRequireDeviceAuth(_ on: Bool) {
        requireDeviceAuth = on
        try? repo?.setSetting("require_device_auth", on ? "1" : nil)
    }

    // MARK: - Sync (design §7)

    /// Sync on launch/foreground if nothing succeeded in four hours.
    func syncIfStale() async {
        guard mode == .live, !isSyncing else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < 4 * 3600 { return }
        await sync()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncMessage = nil
        guard mode == .live || client.isPaired, let engine else {
            try? await Task.sleep(for: .seconds(0.8)) // sample mode: nothing to pull
            lastSync = Date()
            return
        }
        let outcomes = await engine.syncAll()
        var messages: [String] = []
        for o in outcomes {
            if case .failure(let e) = o.result {
                let name = (try? repo?.connection(o.connectionID))??.institution ?? "A bank"
                messages.append("\(name): \(e.localizedDescription)")
            }
        }
        // Right after linking, Plaid may still be preparing history (NOT_READY). Poll briefly instead of
        // waiting for the next foreground sync.
        let preparing = ((try? repo?.connections()) ?? []).contains { $0.status == "active" && $0.historyStatus == "NOT_READY" }
        if preparing && messages.isEmpty { messages.append("Your bank is preparing transaction history…") }
        syncMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
        reload()
        if preparing && notReadyRetries < 12 {
            notReadyRetries += 1
            Task { try? await Task.sleep(for: .seconds(5)); await self.sync() }
        } else if !preparing {
            notReadyRetries = 0
        }
    }

    private var notReadyRetries = 0

    // MARK: - Pairing and connections

    func pair(url: URL, code: String) async throws {
        try await client.pair(baseURL: url, code: code, deviceName: UIDevice.current.name)
        pairing = client.pairing
    }

    func unpair() { client.unpair(); pairing = nil }

    /// Exchanges a Link public token for a connection, stores its accounts, and opens account mapping.
    @discardableResult
    func completeLink(publicToken: String, country: String, clientRequestID: String) async throws -> String {
        guard let repo else { throw DatabaseError.keyUnavailable }
        let remote = try await client.createConnection(publicToken: publicToken, clientRequestID: clientRequestID, country: country)
        let stored = StoredConnection(id: remote.connectionId, institution: remote.institution ?? "Bank", country: remote.country,
                                      environment: client.environment ?? "unknown", status: "active",
                                      cursor: nil, lastSync: nil, historyStatus: nil)
        let accounts = remote.accounts.map {
            SourceAccount(id: $0.id, connectionID: remote.connectionId, name: $0.officialName ?? $0.name, mask: $0.mask,
                          type: $0.type, subtype: $0.subtype, currency: $0.currency, cardID: nil)
        }
        try repo.saveConnection(stored, accounts: accounts)
        return remote.connectionId
    }

    func confirmMapping(connectionID: String, _ mapping: [(account: SourceAccount, productID: String, nickname: String)],
                        hide hidden: [SourceAccount] = []) async {
        do {
            try repo?.confirmMapping(connection: connectionID, mapping)
            try repo?.setIgnored(true, accounts: hidden.map(\.id))
        }
        catch { syncMessage = error.localizedDescription; return }
        pendingMappingConnectionID = nil
        reload()
        await sync()
    }

    /// Update mode finished: the existing Item is repaired, no token exchange needed.
    func completeReauth(connectionID: String) async {
        try? repo?.setStatus("active", connection: connectionID)
        reauthConnectionID = nil
        reload()
        await sync()
    }

    func reconnect(_ cardID: String) {
        guard let card = card(cardID) else { return }
        if mode == .sample {
            if let i = cards.firstIndex(where: { $0.id == cardID }), case .reauthRequired(let inst) = cards[i].connection {
                cards[i].connection = .plaid(institution: inst)
                cards[i].lastSync = Date()
            }
            return
        }
        reauthConnectionID = card.connectionID
    }

    /// Revokes the Plaid Item through the service. On failure the connection stays in a retry state.
    func disconnect(cardID: String) async {
        guard mode == .live, let id = card(cardID)?.connectionID, let repo else { return }
        try? repo.setStatus("disconnect_pending", connection: id)
        do {
            try await client.disconnect(connectionID: id)
            try repo.closeConnection(id)
            syncMessage = nil
        } catch {
            syncMessage = "Disconnect will be retried: \(error.localizedDescription)"
        }
        reload()
    }

    func addManualCard(nickname: String, productID: String, mask: String?, openedOn: Date, renewal: Date?) {
        guard let repo else { storageError = "Encrypted storage is unavailable."; return }
        do { try repo.createManualCard(nickname: nickname, productID: productID, mask: mask, openedOn: openedOn, renewal: renewal) }
        catch { syncMessage = error.localizedDescription; return }
        reload()
    }

    /// Connections from the paired service's environment that still have credit-card accounts to assign.
    /// Connections from another Plaid environment (e.g. Sandbox while paired to Production) can't sync and are skipped.
    var connectionsNeedingMapping: [(connection: StoredConnection, accounts: [SourceAccount])] {
        ((try? repo?.connections()) ?? []).compactMap { c in
            guard c.status != "disconnected", pairing == nil || c.environment == pairing?.environment else { return nil }
            let pending = ((try? repo?.accounts(connection: c.id)) ?? []).filter(\.needsMapping)
            return pending.isEmpty ? nil : (c, pending)
        }
    }

    var hiddenAccountCount: Int { (try? repo?.hiddenAccountCount(environment: pairing?.environment)) ?? 0 }

    func hideAccounts(_ accounts: [SourceAccount]) {
        try? repo?.setIgnored(true, accounts: accounts.map(\.id))
        reload()
    }

    func unhideAccounts() {
        try? repo?.unhideAllAccounts()
        reload()
    }

    func deleteHistory(cardID: String) {
        guard mode == .live else { return }
        try? repo?.deleteCard(cardID)
        reload()
    }

    // MARK: - Wallet summary (RewardRadar-style)

    /// Personal cards opened in the last 24 months (authorized-user cards excluded).
    var fiveTwentyFourCount: Int {
        let cutoff = Day.addMonths(-24, to: today)
        // Cards the owner said are older than their covered history don't count until a real date is entered.
        return cards.filter {
            !$0.isAuthorizedUser && $0.openDateStatus != .older && $0.openedOn > cutoff && Catalog.product($0.productID).market == .usd
        }.count
    }

    func annualFees(_ currency: CurrencyCode) -> Money {
        cards.map { Catalog.product($0.productID).annualFee }.filter { $0.currency == currency }
            .reduce(.zero(currency), +)
    }

    var welcomeOffers: [WelcomeOffer] = []
    var usageLogs: [UsageLog] = []
    var certificates: [AwardCertificate] = []

    // MARK: - In-app credits, certificates, memberships

    func usage(for periodID: String) -> [UsageLog] { usageLogs.filter { $0.periodID == periodID } }

    /// Records use of an in-app credit. Sample cards keep it in memory only.
    func logUsage(periodID: String, amount: Money, usedOn: Date, note: String) {
        let log = UsageLog(id: UUID().uuidString, periodID: periodID, amount: amount, usedOn: usedOn, note: note)
        if mode == .live { try? repo?.addUsage(log) }
        usageLogs.append(log)
        recompute()
    }

    func deleteUsage(_ id: String) {
        if mode == .live { try? repo?.deleteUsage(id) }
        usageLogs.removeAll { $0.id == id }
        recompute()
    }

    func certificateStatuses(for card: Card) -> [CertificateStatus] {
        NonCreditEngine.certificateStatuses(card: card, renewal: renewal(card), certificates: certificates,
                                            transactions: effectiveTransactions, today: today)
    }

    /// Unused certificates across all cards, soonest expiry first (Overview).
    var availableCertificates: [AwardCertificate] {
        certificates.filter { $0.state(today: today) == .available }.sorted { $0.expiresOn < $1.expiresOn }
    }

    /// Awards that are due or coming within 60 days and not yet recorded (Overview).
    var expectedAwards: [CertificateStatus] {
        cards.flatMap(certificateStatuses).filter { st in
            guard let from = st.expectedFrom else { return false }
            return st.pending || Day.days(from: today, to: from) <= 60
        }
        .sorted { ($0.expectedBy ?? .distantFuture) < ($1.expectedBy ?? .distantFuture) }
    }

    func saveCertificate(_ c: AwardCertificate) {
        if mode == .live { try? repo?.saveCertificate(c) }
        certificates.removeAll { $0.id == c.id }
        certificates.append(c)
    }

    func deleteCertificate(_ id: String) {
        if mode == .live { try? repo?.deleteCertificate(id) }
        certificates.removeAll { $0.id == id }
    }

    private func membershipKey(_ card: Card, _ rule: BenefitRule) -> String { "membership.\(card.id).\(rule.id)" }

    func membershipActivated(_ card: Card, _ rule: BenefitRule) -> Date? {
        Day.parse(repo?.setting(membershipKey(card, rule)) ?? membershipMemory[membershipKey(card, rule)])
    }

    func setMembership(_ card: Card, _ rule: BenefitRule, activatedOn: Date?) {
        let key = membershipKey(card, rule)
        if mode == .live { try? repo?.setSetting(key, activatedOn.map { Day.key($0) }) }
        membershipMemory[key] = activatedOn.map { Day.key($0) }
    }

    var membershipMemory: [String: String] = [:]

    func offers(for cardID: String) -> [WelcomeOffer] { welcomeOffers.filter { $0.cardID == cardID } }

    func progress(_ offer: WelcomeOffer) -> WelcomeOfferProgress {
        WelcomeOfferEngine.progress(offer, transactions: effectiveTransactions, today: today)
    }

    /// Offers still running, soonest deadline first (Overview).
    var activeOffers: [WelcomeOfferProgress] {
        welcomeOffers.map(progress).filter { $0.state == .inProgress || $0.state == .active }
            .sorted { $0.offer.end < $1.offer.end }
    }

    func confirmOpenDate(_ cardID: String, date: Date?, status: OpenDateStatus) {
        try? repo?.setOpenDate(cardID: cardID, date: date, status: status)
        reload()
    }

    func saveOffer(_ offer: WelcomeOffer) {
        guard let card = card(offer.cardID) else { return }
        try? repo?.saveWelcomeOffer(offer, currency: Catalog.product(card.productID).market)
        reload()
    }

    func deleteOffer(_ id: String) {
        try? repo?.deleteWelcomeOffer(id)
        reload()
    }

    func effectiveFee(_ card: Card) -> Money {
        // A first-year fee waiver means no fee was charged in the first cardmember year.
        if offers(for: card.id).contains(where: { $0.kind == .feeWaiver && today < $0.end }) {
            return .zero(Catalog.product(card.productID).annualFee.currency)
        }
        let fee = Catalog.product(card.productID).annualFee
        let redeemed = BenefitEngine.creditsRedeemed(card: card, periods: benefits.periods, since: Day.addMonths(-12, to: today))
        return fee - redeemed
    }

    func renewal(_ card: Card) -> RenewalDate? {
        if let r = BenefitEngine.renewal(for: card, transactions: transactions) { return r }
        // Without a posted fee or entered date, a confirmed open date gives the account anniversary.
        guard card.openDateStatus == .confirmed else { return nil }
        var next = card.openedOn
        while next < Day.startOfMonth(today) { next = Day.addMonths(12, to: next) }
        return RenewalDate(date: next, precision: .day, source: .openAnniversary)
    }

    var upcomingFees: [(Card, RenewalDate)] {
        cards.compactMap { c in renewal(c).map { (c, $0) } }
            .filter { Day.days(from: today, to: $0.1.date) <= 120 && $0.1.date >= Day.startOfMonth(today) }
            .sorted { $0.1.date < $1.1.date }
    }
}
