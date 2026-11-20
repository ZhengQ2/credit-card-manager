import SwiftUI

/// RewardRadar-style "which card should I use?", driven by the real ledger for remaining caps.
struct BestCardView: View {
    @Environment(Store.self) private var store
    @State private var currency: CurrencyCode = .cad
    @State private var expanded: RewardCategory?
    @State private var search = ""

    private func categories(in group: RewardCategory.Group) -> [RewardCategory] {
        RewardCategory.allCases.filter { category in
            category.group == group && (
                search.isEmpty
                || category.title.localizedCaseInsensitiveContains(search)
                || group.rawValue.localizedCaseInsensitiveContains(search)
            )
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Purchase currency", selection: $currency) {
                        ForEach(CurrencyCode.allCases) { Text("Paying in \($0.rawValue)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Value per \(currency.rawValue) 100 spent, at your point valuations. Cross-border cards include FX fees and your exchange-rate assumption.")
                }

                let engine = store.rewards
                let capUsage = engine.capUsage(from: store.effectiveTransactions, through: store.today)
                ForEach(RewardCategory.Group.allCases) { group in
                    let groupCategories = categories(in: group)
                    if !groupCategories.isEmpty && !store.cards.isEmpty {
                        Section(group.rawValue) {
                            ForEach(groupCategories) { category in
                                let ranking = engine.rank(category: category, currency: currency, amount: Money(10_000, currency),
                                                          usage: capUsage, today: store.today)
                                let pinned = store.pinnedCard[category]
                                if !ranking.isEmpty {
                                    CategoryRow(category: category, ranking: ranking, pinnedID: pinned, currency: currency,
                                                isExpanded: expanded == category) {
                                        withAnimation { expanded = expanded == category ? nil : category }
                                    }
                                    if expanded == category {
                                        ForEach(ranking, id: \.card.id) { q in
                                            RankedQuoteRow(quote: q, currency: currency, isPinned: pinned == q.card.id) {
                                                store.pinnedCard[category] = pinned == q.card.id ? nil : q.card.id
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Best Card")
            .searchable(text: $search, prompt: "Search categories")
        }
    }
}

struct CategoryRow: View {
    let category: RewardCategory
    let ranking: [EarnQuote]
    let pinnedID: String?
    let currency: CurrencyCode
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        if let best = ranking.first {
            let pinned = ranking.first { $0.card.id == pinnedID }
            let shown = pinned ?? best
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: category.symbol)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.title).font(.body.weight(.semibold))
                        HStack(spacing: 6) {
                            CardChip(card: shown.card, size: 14)
                            Text(shown.card.nickname)
                            if pinned != nil { Image(systemName: "pin.fill").font(.caption2) }
                            if shown.uncertain { Text("· varies").foregroundStyle(.orange) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let cap = shown.capNote {
                            Text(cap).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(percent(shown.netValueMinor))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
            .accessibilityLabel("\(category.title): \(shown.card.nickname), \(percent(shown.netValueMinor)) back")
            .accessibilityHint(isExpanded ? "Collapse ranking" : "Show all cards")
        }
    }

    private func percent(_ minorPer100: Double) -> String {
        "\((minorPer100 / 100).formatted(.number.precision(.fractionLength(1))))%"
    }
}

struct RankedQuoteRow: View {
    let quote: EarnQuote
    let currency: CurrencyCode
    let isPinned: Bool
    let onPin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CardChip(card: quote.card, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.card.nickname).font(.callout)
                Text(quote.explanation).font(.caption).foregroundStyle(.secondary)
                if let note = quote.ruleNote { Text(note).font(.caption2).foregroundStyle(.secondary) }
                if let cap = quote.capNote { Text(cap).font(.caption2).foregroundStyle(.orange) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\((quote.netValueMinor / 100).formatted(.number.precision(.fractionLength(2))))%")
                    .font(.callout.monospacedDigit())
                Button(action: onPin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPinned ? "Unpin \(quote.card.nickname)" : "Pin \(quote.card.nickname) for this category")
            }
        }
        .padding(.leading, 8)
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false
    @State private var confirmDelete = false
    @State private var accountError: String?
    @State private var billConsent: IdentifiedString?
    @State private var billWithdrawal: StoredConnection?
    @State private var billWithdrawalMessage: String?
    @State private var changingBillAlerts = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    if let p = store.serviceSession {
                        LabeledContent("Signed in as", value: p.email)
                        LabeledContent("Environment", value: p.environment)
                        if p.baseURL != ServiceClient.defaultBaseURL {
                            LabeledContent("Service", value: p.baseURL.host() ?? p.baseURL.absoluteString)
                        }
                        NavigationLink("Sign-in security") { AccountSecurityView() }
                        Button("Sign out") { Task { await store.signOut() } }
                        Button("Delete account…", role: .destructive) { confirmDelete = true }
                    } else {
                        Button("Sign in…") { showSignIn = true }
                    }
                    LabeledContent("Data on this iPhone", value: store.mode == .live ? "Your ledger (encrypted)" : "Sample data")
                    if let accountError { Text(accountError).font(.callout).foregroundStyle(.red) }
                } header: { Text("Account") } footer: {
                    Text("Card Ledger keeps your account and bank connections on the service. Plaid supplies authorized card data. Transactions pass through the service and are saved only in the encrypted ledger on this iPhone.")
                }
                .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete account and bank links", role: .destructive) {
                        Task {
                            do { try await store.deleteAccount(); accountError = nil }
                            catch { accountError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                        }
                    }
                } message: {
                    Text("Every bank connection is removed at Plaid and your account is erased from the service. The ledger already on this iPhone stays until you delete local history.")
                }

                Section {
                    Toggle("Require device authentication", isOn: Binding(get: { store.requireDeviceAuth }, set: { store.setRequireDeviceAuth($0) }))
                    LabeledContent("Storage", value: store.storageError == nil ? "SQLCipher, AES-256" : "Unavailable")
                } header: { Text("Security") } footer: {
                    Text("Unlock with Face ID, Touch ID, or your device passcode.")
                }

                Section("Reminders") {
                    ForEach([14, 7, 2], id: \.self) { d in
                        Toggle("\(d) days before a deadline", isOn: Binding(
                            get: { store.reminderOffsets.contains(d) },
                            set: { on in if on { store.reminderOffsets.insert(d) } else { store.reminderOffsets.remove(d) } }))
                    }
                    Text("Delivered at 9 AM with a generic lock-screen message.").font(.caption).foregroundStyle(.secondary)
                }

                billAlertSection

                Section {
                    ForEach(Catalog.programs) { p in
                        Stepper(value: Binding(
                            get: { store.assumptions.centsPerPoint[p.id] ?? p.defaultCentsPerPoint },
                            set: { store.assumptions.centsPerPoint[p.id] = $0 }), in: 0.1...3.0, step: 0.1) {
                            VStack(alignment: .leading) {
                                Text(p.name)
                                Text("\((store.assumptions.centsPerPoint[p.id] ?? 0).formatted(.number.precision(.fractionLength(1))))¢ \(p.currency.rawValue) per point")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Point values") } footer: {
                    Text("Used by Best Card and Compare. Your valuation, not a market rate.")
                }

                Section("Exchange-rate assumption") {
                    Stepper(value: $store.assumptions.cadPerUSD, in: 1.0...1.8, step: 0.01) {
                        Text("1 USD = \(store.assumptions.cadPerUSD.formatted(.number.precision(.fractionLength(2)))) CAD")
                    }
                }

                Section {
                    Toggle("Count card-linked offers", isOn: Binding(get: { store.countOffersInFee }, set: { store.setCountOffersInFee($0) }))
                } header: { Text("Effective annual fee") } footer: {
                    Text("Offers you earned in the last 12 months, such as Amex Offers, are subtracted from each card's annual fee along with the card's own credits.")
                }

                Section("Privacy") {
                    LabeledContent("Ledger iCloud sync", value: "Off")
                    LabeledContent("Analytics", value: "None")
                    Button("Export encrypted archive…") {}
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSignIn) { SignInView() }
            .sheet(item: $billConsent) { ReauthView(connectionID: $0.id, billAccess: true) }
            .confirmationDialog("Withdraw bill-date access?", isPresented: Binding(
                get: { billWithdrawal != nil }, set: { if !$0 { billWithdrawal = nil } }
            ), titleVisibility: .visible, presenting: billWithdrawal) { connection in
                Button("Withdraw access", role: .destructive) {
                    Task {
                        billWithdrawalMessage = nil
                        do { try await store.withdrawBillAccess(connectionID: connection.id) }
                        catch {
                            billWithdrawalMessage = store.billWithdrawalPending(connection.id)
                                ? "Bill dates are turned off on this iPhone. Retry withdrawal to finish on the service."
                                : error.localizedDescription
                        }
                    }
                }
            } message: { connection in
                Text("Automatic due dates and reminders for \(connection.institution) will be unavailable. To remove the Plaid connection entirely, disconnect the bank in Cards.")
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var billAlertSection: some View {
        Section {
            Toggle("Bill payment alerts", isOn: Binding(get: { store.billAlertsEnabled }, set: { value in
                changingBillAlerts = true
                Task {
                    defer { changingBillAlerts = false }
                    await store.setBillAlertsEnabled(value)
                }
            }))
            .disabled(changingBillAlerts || !store.isSignedIn)

            if store.billAlertsEnabled {
                let connections = store.billConnections
                if connections.isEmpty {
                    Text(store.isSignedIn ? "Link a bank and add a credit card to check for due dates."
                                        : "Sign in to your account to check for due dates.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connections) { connection in
                        billAlertStatus(connection)
                    }
                    Button {
                        Task { await store.refreshBillAlerts(force: true) }
                    } label: {
                        HStack {
                            Text("Refresh payment dates")
                            if store.isRefreshingBills { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(store.isRefreshingBills)
                }
            }
            ForEach(store.billConnections) { connection in
                Button(store.billWithdrawalPending(connection.id)
                       ? "Retry withdrawing bill access for \(connection.institution)"
                       : "Withdraw bill access for \(connection.institution)") {
                    billWithdrawal = connection
                }
                .disabled(store.withdrawingBillAccess.contains(connection.id))
            }
            if let billWithdrawalMessage { Text(billWithdrawalMessage).font(.callout).foregroundStyle(.secondary) }
            if let message = store.billNotifications.message ?? store.billRefreshMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Credit card bills")
        } footer: {
            Text("Turning alerts off stops automatic due dates and payment reminders on this iPhone and clears saved dates. Withdraw bill access above to stop future collection for a bank across devices.")
        }
    }

    @ViewBuilder
    private func billAlertStatus(_ connection: StoredConnection) -> some View {
        if store.billWithdrawalPending(connection.id) {
            LabeledContent(connection.institution, value: "Withdrawal pending")
        } else if connection.status == "login_required" {
            LabeledContent(connection.institution, value: "Reconnect in Cards")
        } else if let report = store.billReport(for: connection.id) {
            switch report.response.status {
            case .consentRequired:
                Button("Authorize bill dates for \(connection.institution)") { billConsent = IdentifiedString(id: connection.id) }
            case .disabled:
                LabeledContent(connection.institution, value: "Bill data disabled on the service")
            case .unavailable:
                LabeledContent(connection.institution, value: "Bill dates unavailable")
            case .available:
                let hasDueDate = report.response.bills.contains { ($0.day ?? .distantPast) >= Day.today }
                LabeledContent(connection.institution, value: hasDueDate ? "Payment dates synced" : "No upcoming due date reported")
            }
        }
    }
}
