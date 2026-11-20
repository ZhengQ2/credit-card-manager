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
    var assumptions = Assumptions() { didSet { persistAssumptions() } }
    var pinnedCard: [RewardCategory: String] = [:] { didSet { persistPinnedCards() } }
    var categoryOverrides: [String: RewardCategory] = [:]
    var reminderOffsets: Set<Int> = [7, 2] { didSet { persistReminderOffsets() } }
    var isSyncing = false
    var lastSync: Date?
    var mode: DataMode = .sample
    var storageError: String?
    var syncMessage: String?
    var unknownCurrencyCount = 0
    var requireDeviceAuth = false
    /// Whether card-linked offers earned reduce the effective annual fee (on by default).
    var countOffersInFee = true
    var billAlertsEnabled = false
    var billReports: [String: BillReport] = [:]
    @ObservationIgnored var billAccessRevision: [String: Int] = [:]
    var withdrawingBillAccess: Set<String> = []
    var billRefreshMessage: String?
    var isRefreshingBills = false
    @ObservationIgnored var needsBillRefresh = false
    let billNotifications = BillNotifications()

    // Card Ledger API and Plaid
    let client = ServiceClient()
    private(set) var repo: LedgerRepository?
    private var engine: SyncEngine?
    /// Mirrors the signed-in account so views observe sign-in and sign-out.
    private(set) var serviceSession: AccountSession?
    var isSignedIn: Bool { serviceSession != nil }
    var serviceEnvironment: String? { serviceSession?.environment }
    /// Connections whose credit-card accounts still need to be mapped to cards.
    var pendingMappingConnectionID: String?
    var billSetupAfterMappingID: String?
    /// Set when a card needs Plaid Link update mode.
    var reauthConnectionID: String?

    // Cross-tab navigation
    var selectedTab: Tab = .overview
    var activityCategory: RewardCategory?
    var activityCardID: String?

    enum Tab: Hashable { case overview, cards, activity, spending, bestCard }

    private(set) var benefits = BenefitResult()
    private(set) var effectiveTransactions: [Transaction] = []
    @ObservationIgnored private var effectiveByID: [String: Transaction] = [:]
    @ObservationIgnored private var isLoadingSettings = false
    @ObservationIgnored private var notReadyRetryTask: Task<Void, Never>?

    init(today: Date = Day.today) {
        self.today = today
        // Keychain entries outlive an uninstall; the data container does not. Start clean on a fresh install,
        // but NEVER delete the database key if an encrypted ledger file already exists on disk.
        if !UserDefaults.standard.bool(forKey: "installed.v1") {
            if !EncryptedDatabase.hasExistingDatabase() {
                Keychain.delete(.serviceCredential)
                Keychain.delete(.databaseKey)
                client.forgetLocally()
            }
            UserDefaults.standard.set(true, forKey: "installed.v1")
        }
        serviceSession = client.account
        client.onSessionEnded = { [weak self] in self?.endSessionLocally() }
        do {
            let db = try EncryptedDatabase()
            let repo = try LedgerRepository(db: db)
            self.repo = repo
            self.engine = SyncEngine(client: client, repo: repo)
            loadPersistedSettings(from: repo)
        } catch {
            storageError = error.localizedDescription
        }
        reload()
    }

    private func loadPersistedSettings(from repo: LedgerRepository) {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        try? repo.dropUnmappedNonCardAccounts()
        requireDeviceAuth = repo.setting("require_device_auth") == "1"
        countOffersInFee = repo.setting("count_offers_in_fee") != "0"
        billAlertsEnabled = serviceSession.map { repo.setting("bill_alert_choice.\($0.userID)") == "enabled" } ?? false
        for (key, value) in (try? repo.settings(prefix: "bill_report.")) ?? [:] where key.hasPrefix("bill_report.") {
            if billAlertsEnabled, let session = serviceSession,
               let report = try? JSONDecoder().decode(BillReport.self, from: Data(value.utf8)),
               report.accountUserID == session.userID, report.serviceURL == session.baseURL {
                billReports[String(key.dropFirst("bill_report.".count))] = report
            } else {
                try? repo.setSetting(key, nil)
            }
        }
        if let raw = repo.setting("assumptions")?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Assumptions.self, from: raw) {
            // Merge with catalog defaults so newly added programs keep their default valuation.
            var merged = Assumptions()
            merged.cadPerUSD = decoded.cadPerUSD
            for (k, v) in decoded.centsPerPoint { merged.centsPerPoint[k] = v }
            assumptions = merged
        }
        if let raw = repo.setting("pinned_card")?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: raw) {
            var map: [RewardCategory: String] = [:]
            for (k, v) in decoded { if let cat = RewardCategory(rawValue: k) { map[cat] = v } }
            pinnedCard = map
        }
        if let raw = repo.setting("reminder_offsets")?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Int].self, from: raw) {
            reminderOffsets = Set(decoded)
        }
    }

    private func persistAssumptions() {
        guard !isLoadingSettings, let data = try? JSONEncoder().encode(assumptions),
              let json = String(data: data, encoding: .utf8) else { return }
        try? repo?.setSetting("assumptions", json)
    }

    private func persistPinnedCards() {
        guard !isLoadingSettings else { return }
        let raw = Dictionary(uniqueKeysWithValues: pinnedCard.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw), let json = String(data: data, encoding: .utf8) else { return }
        try? repo?.setSetting("pinned_card", json)
    }

    private func persistReminderOffsets() {
        guard !isLoadingSettings, let data = try? JSONEncoder().encode(reminderOffsets.sorted()),
              let json = String(data: data, encoding: .utf8) else { return }
        try? repo?.setSetting("reminder_offsets", json)
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
            membershipMemory = (try? repo.settings(prefix: "membership.")) ?? [:]
            statementBills = (try? repo.statementBills()) ?? [:]
            lastSync = cards.compactMap(\.lastSync).max()
        } else {
            let wasLive = mode == .live
            mode = .sample
            cards = SampleData.cards(today: today)
            transactions = SampleData.transactions(today: today)
            lastSync = Date().addingTimeInterval(-60 * 42)
            unknownCurrencyCount = 0
            if wasLive {
                welcomeOffers = []
                usageLogs = []
                certificates = []
                membershipMemory = [:]
                statementBills = [:]
            }
        }
        recompute()
        updateStatementBillNotifications()
    }

    func recompute() {
        let effective = transactions.map { t in
            guard let c = categoryOverrides[t.id] else { return t }
            return Transaction(id: t.id, cardID: t.cardID, amount: t.amount, posted: t.posted, authorized: t.authorized,
                               merchant: t.merchant, originalDescription: t.originalDescription, category: c, kind: t.kind,
                               pending: t.pending, provenance: t.provenance, mcc: t.mcc)
        }
        effectiveTransactions = effective
        effectiveByID = Dictionary(uniqueKeysWithValues: effective.map { ($0.id, $0) })
        let usage = Dictionary(grouping: usageLogs, by: \.periodID).mapValues { $0.reduce(0) { $0 + $1.amount.minor } }
        benefits = BenefitEngine.evaluate(cards: cards, transactions: effective, decisions: decisions, today: today,
                                          usage: usage)
    }

    var rewards: RewardsEngine {
        let renewals = Dictionary(uniqueKeysWithValues: cards.compactMap { c in renewal(c).map { (c.id, $0) } })
        return RewardsEngine(cards: cards, assumptions: assumptions, renewals: renewals)
    }

    func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    func transaction(_ id: String) -> Transaction? { effectiveByID[id] }

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

    func setCountOffersInFee(_ on: Bool) {
        countOffersInFee = on
        try? repo?.setSetting("count_offers_in_fee", on ? nil : "0")
    }

    func setRequireDeviceAuth(_ on: Bool) {
        requireDeviceAuth = on
        try? repo?.setSetting("require_device_auth", on ? "1" : nil)
    }

    // MARK: - Sync (design §7)

    /// Sync on launch/foreground if nothing succeeded in four hours.
    func syncIfStale() async {
        // Re-check local statement notification scheduling on foreground resume so permission changes in iOS Settings take effect.
        lastStatementAlertSignature = nil
        if mode == .live, today != Day.today { reload() }
        if mode == .live, !isSyncing, lastSync.map({ Date().timeIntervalSince($0) >= 4 * 3600 }) ?? true {
            await sync(forceBillRefresh: false)
        } else {
            await refreshBillAlerts()
        }
    }

    func sync(forceBillRefresh: Bool = true) async {
        if isSyncing {
            if forceBillRefresh { await refreshBillAlerts(force: true) }
            return
        }
        notReadyRetryTask?.cancel()
        notReadyRetryTask = nil
        isSyncing = true
        defer { isSyncing = false }
        syncMessage = nil
        guard mode == .live, let engine else {
            try? await Task.sleep(for: .seconds(0.8)) // sample mode: nothing to pull
            lastSync = Date()
            return
        }
        let outcomes = await engine.syncAll()
        if !client.isSignedIn, serviceSession != nil { endSessionLocally() } // the service ended the session
        var messages: [String] = []
        for o in outcomes {
            if case .failure(let e) = o.result {
                if e is CancellationError { continue }
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
        Task { await refreshBillAlerts(force: forceBillRefresh) }
        if preparing && isSignedIn && notReadyRetries < 12 {
            notReadyRetries += 1
            notReadyRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.isSignedIn else { return }
                await self.sync(forceBillRefresh: false)
            }
        } else if !preparing {
            notReadyRetries = 0
        }
    }

    private var notReadyRetries = 0

    // MARK: - Account and connections

    /// Emails a sign-in code. Returns the service's Plaid environment.
    func startSignIn(url: URL, email: String) async throws -> String {
        try await client.startSignIn(baseURL: url, email: email).environment
    }

    func completeSignIn(url: URL, environment: String, email: String, code: String) async throws -> ServiceClient.SecondFactor? {
        let challenge = try await client.completeSignIn(baseURL: url, environment: environment, email: email, code: code)
        if challenge == nil { didSignIn() }
        return challenge
    }

    func didSignIn() {
        updateAccountSession()
        syncMessage = nil
        Task { await sync() } // also refreshes bill dates
    }

    func updateAccountSession() {
        let previous = serviceSession?.userID
        serviceSession = client.account
        if previous != serviceSession?.userID {
            billAlertsEnabled = serviceSession.map { repo?.setting("bill_alert_choice.\($0.userID)") == "enabled" } ?? false
            updateBillNotifications()
        }
    }

    func signOut() async {
        await client.signOut()
        endSessionLocally()
    }

    /// Deletes the account on the service (removing every bank link at Plaid). The local ledger stays on this iPhone.
    func deleteAccount() async throws {
        try await client.deleteAccount()
        endSessionLocally()
    }

    private func endSessionLocally() {
        notReadyRetryTask?.cancel()
        notReadyRetryTask = nil
        if client.isSignedIn { client.forgetLocally() }
        serviceSession = nil
        billAlertsEnabled = false
        billReports.removeAll()
        try? repo?.clearBillReports()
        updateBillNotifications()
    }

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
        }.filter(\.isCreditCard)
        try repo.saveConnection(stored, accounts: accounts)
        return remote.connectionId
    }

    func confirmMapping(connectionID: String, _ mapping: [(account: SourceAccount, productID: String, nickname: String)],
                        hide hidden: [SourceAccount] = []) -> Bool {
        guard let repo else { return false }
        do {
            try repo.confirmMapping(connection: connectionID, mapping)
            try repo.setIgnored(true, accounts: hidden.map(\.id))
        }
        catch { syncMessage = error.localizedDescription; return false }
        reload()
        Task { await sync(forceBillRefresh: true) }
        return true
    }

    /// Update mode finished: the existing Item is repaired, no token exchange needed.
    func completeReauth(connectionID: String) async {
        try? repo?.setStatus("active", connection: connectionID)
        reauthConnectionID = nil
        reload()
        await sync(forceBillRefresh: true)
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
        removeBillReport(connectionID: id)
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
            guard c.status != "disconnected", serviceSession == nil || c.environment == serviceSession?.environment else { return nil }
            let pending = ((try? repo?.accounts(connection: c.id)) ?? []).filter(\.needsMapping)
            return pending.isEmpty ? nil : (c, pending)
        }
    }

    var hiddenAccountCount: Int { (try? repo?.hiddenAccountCount(environment: serviceSession?.environment)) ?? 0 }

    func hideAccounts(_ accounts: [SourceAccount]) {
        try? repo?.setIgnored(true, accounts: accounts.map(\.id))
        reload()
    }

    func unhideAccounts() {
        try? repo?.unhideAllAccounts()
        reload()
    }

    func deleteHistory(cardID: String) {
        guard mode == .live, let repo else { return }
        let connectionID = card(cardID)?.connectionID
        do {
            try repo.deleteCard(cardID)
            try? repo.saveStatementBill(nil, cardID: cardID)
        }
        catch { syncMessage = error.localizedDescription; return }
        if let connectionID { billReports[connectionID] = repo.billReport(connectionID: connectionID) }
        reload()
        updateBillNotifications()
    }

    // MARK: - Wallet summary (RewardRadar-style)

    /// Personal cards opened in the last 24 months (authorized-user and business cards excluded).
    var fiveTwentyFourCount: Int {
        let cutoff = Day.addMonths(-24, to: today)
        // Cards the owner said are older than their covered history don't count until a real date is entered.
        return cards.filter {
            let p = Catalog.product($0.productID)
            return !$0.isAuthorizedUser && !p.isBusiness && $0.openDateStatus != .older && $0.openedOn > cutoff && p.market == .usd
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
        Day.parse(membershipMemory[membershipKey(card, rule)])
    }

    func setMembership(_ card: Card, _ rule: BenefitRule, activatedOn: Date?) {
        let key = membershipKey(card, rule)
        let value = activatedOn.map { Day.key($0) }
        if mode == .live {
            do { try repo?.setSetting(key, value) }
            catch { syncMessage = error.localizedDescription; return }
        }
        membershipMemory[key] = value
    }

    var membershipMemory: [String: String] = [:]
    var statementBills: [String: StatementBill] = [:]
    @ObservationIgnored var lastStatementAlertSignature: [String]?
    let statementBillNotifications = StatementBillNotifications()

    func offers(for cardID: String) -> [WelcomeOffer] { welcomeOffers.filter { $0.cardID == cardID } }

    func progress(_ offer: WelcomeOffer) -> WelcomeOfferProgress {
        let cardCurrency = card(offer.cardID).map { Catalog.product($0.productID).market }
        return WelcomeOfferEngine.progress(offer, transactions: effectiveTransactions, today: today, cardCurrency: cardCurrency)
    }

    /// Offers still running, soonest deadline first (Overview).
    var activeOffers: [WelcomeOfferProgress] {
        welcomeOffers.map(progress).filter { $0.state == .inProgress || $0.state == .active }
            .sorted { $0.offer.end < $1.offer.end }
    }

    func confirmOpenDate(_ cardID: String, date: Date?, status: OpenDateStatus) {
        if mode == .live {
            do { try repo?.setOpenDate(cardID: cardID, date: date, status: status) }
            catch { syncMessage = error.localizedDescription; return }
            reload()
        } else if let idx = cards.firstIndex(where: { $0.id == cardID }) {
            if let date { cards[idx].openedOn = date }
            cards[idx].openDateStatus = status
            cards[idx].openedIsEstimate = (status == .estimated)
            recompute()
        }
    }

    /// Changes a card's catalog product. Earn rates, credits, fees and certificates follow the new product;
    /// transactions, open date, renewal date and welcome offer stay. A nickname that was just the old product's
    /// name follows the new product; a custom nickname is kept.
    func changeProduct(_ cardID: String, to productID: String) {
        guard let card = card(cardID), card.productID != productID else { return }
        let old = Catalog.product(card.productID)
        let new = Catalog.product(productID)
        let nickname = [old.name, old.displayName].contains(card.nickname) ? new.name : card.nickname
        if mode == .live {
            do { try repo?.setProduct(cardID: cardID, productID: productID, nickname: nickname) }
            catch { syncMessage = error.localizedDescription; return }
            reload()
        } else if let idx = cards.firstIndex(where: { $0.id == cardID }) {
            cards[idx].productID = productID
            cards[idx].nickname = nickname
            recompute()
        }
    }

    func setRenewal(_ cardID: String, date: Date?) {
        if mode == .live {
            do { try repo?.setRenewal(cardID: cardID, date: date) }
            catch { syncMessage = error.localizedDescription; return }
            reload()
        } else if let idx = cards.firstIndex(where: { $0.id == cardID }) {
            cards[idx].renewal = date.map { RenewalDate(date: $0, precision: .day, source: .owner) }
            recompute()
        }
    }

    func saveOffer(_ offer: WelcomeOffer) {
        guard let card = card(offer.cardID) else { return }
        var o = offer
        o.currency = Catalog.product(card.productID).market
        if mode == .live {
            do { try repo?.saveWelcomeOffer(o, currency: o.currency) }
            catch { syncMessage = error.localizedDescription; return }
            reload()
        } else {
            welcomeOffers.removeAll { $0.id == o.id }
            welcomeOffers.append(o)
        }
    }

    func deleteOffer(_ id: String) {
        if mode == .live {
            do { try repo?.deleteWelcomeOffer(id) }
            catch { syncMessage = error.localizedDescription; return }
            reload()
        } else {
            welcomeOffers.removeAll { $0.id == id }
        }
    }

    func creditsRedeemed(for card: Card) -> Money {
        BenefitEngine.creditsRedeemed(card: card, periods: benefits.periods, transactions: effectiveTransactions,
                                      usageLogs: usageLogs, since: Day.addMonths(-12, to: today), today: today)
    }

    func effectiveFee(_ card: Card) -> Money {
        // A first-year fee waiver means no fee was charged in the first cardmember year.
        if offers(for: card.id).contains(where: { $0.kind == .feeWaiver && today < $0.end }) {
            return .zero(Catalog.product(card.productID).annualFee.currency)
        }
        let fee = Catalog.product(card.productID).annualFee
        let offers = countOffersInFee ? offersEarned(for: card) : .zero(fee.currency)
        return fee - creditsRedeemed(for: card) - offers
    }

    /// Card-linked offer credits posted in the last 12 months (the same window as credits used), newest first.
    func offerCredits(for card: Card) -> [Transaction] {
        let since = Day.addMonths(-12, to: today)
        return effectiveTransactions
            .filter { $0.cardID == card.id && $0.kind == .offerCredit && !$0.pending && $0.posted > since && $0.posted <= today }
            .sorted { $0.posted > $1.posted }
    }

    /// Value of card-linked offers earned in the last 12 months, in the card's fee currency.
    func offersEarned(for card: Card) -> Money {
        let currency = Catalog.product(card.productID).annualFee.currency
        let minor = offerCredits(for: card).filter { $0.amount.currency == currency }.reduce(0) { $0 - $1.amount.minor }
        return Money(minor, currency)
    }

    /// Offers earned across all cards in the last 12 months, per currency.
    var offersEarnedByCurrency: [(currency: CurrencyCode, count: Int, total: Money)] {
        let since = Day.addMonths(-12, to: today)
        let rows = effectiveTransactions.filter { $0.kind == .offerCredit && !$0.pending && $0.posted > since && $0.posted <= today }
        return Dictionary(grouping: rows, by: \.amount.currency)
            .map { ($0.key, $0.value.count, Money($0.value.reduce(0) { $0 - $1.amount.minor }, $0.key)) }
            .sorted { $0.currency.rawValue < $1.currency.rawValue }
    }

    func renewal(_ card: Card) -> RenewalDate? {
        BenefitEngine.renewal(for: card, transactions: transactions, today: today)
    }

    var upcomingFees: [(Card, RenewalDate)] {
        cards.compactMap { c in renewal(c).map { (c, $0) } }
            .filter { Day.days(from: today, to: $0.1.date) <= 120 && $0.1.date >= Day.startOfMonth(today) }
            .sorted { $0.1.date < $1.1.date }
    }
}
