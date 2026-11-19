import SwiftUI
import LinkKit

// MARK: - Pairing

struct PairingView: View {
    @SwiftUI.Environment(Store.self) private var store
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var url = "http://127.0.0.1:8787"
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Service URL", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Pairing code", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("On the computer running your service, run `npm run pair` to get a single-use code. Use an https address on your LAN or VPN for a physical iPhone.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack { Text("Verify and pair"); if working { Spacer(); ProgressView() } }
                    }
                    .disabled(working
                              || code.trimmingCharacters(in: .whitespacesAndNewlines).count < 8
                              || URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host == nil)
                }
            }
            .navigationTitle("Pair with service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func pair() async {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return }
        working = true; error = nil
        defer { working = false }
        do {
            try await store.pair(url: u, code: code)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case ServiceError.server(let c, _) = error, c.hasPrefix("pairing_") {
                self.error = "That code is invalid or expired. Generate a new one with `npm run pair`."
            }
        }
    }
}

// MARK: - Connect a bank with Plaid Link

struct ConnectBankView: View {
    @SwiftUI.Environment(Store.self) private var store
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var country = "US"
    @State private var link = LinkPresenter()
    @State private var showMockLink = false
    @State private var working = false
    @State private var error: String?
    /// Reused across retries so the service deduplicates the exchange.
    @State private var clientRequestID = UUID().uuidString
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            Form {
                if !store.isPaired {
                    Section {
                        Text("Pair this iPhone with your owner service first.")
                        Button("Pair with service…") { showPairing = true }
                    }
                } else {
                    Section {
                        Picker("Bank country", selection: $country) {
                            Text("United States").tag("US")
                            Text("Canada").tag("CA")
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Plaid Link asks your bank for up to 24 months of transactions. Supported banks can also share credit card due dates for alerts.")
                    }
                    if let error {
                        Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    }
                    Section {
                        Button { Task { await start() } } label: {
                            HStack { Text("Continue to Plaid"); if working { Spacer(); ProgressView() } }
                        }
                        .disabled(working)
                        if store.serviceEnvironment == "sandbox" {
                            Button("Use Sandbox test bank (skip Link)") { Task { await useTestBank() } }.disabled(working)
                        }
                    } footer: {
                        Text("Service environment: \(store.serviceEnvironment ?? "unknown"). Closing Link returns here without changing any card.")
                    }
                }
            }
            .navigationTitle("Connect a bank")
            .sheet(isPresented: $showPairing) { PairingView() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Mock bank", isPresented: $showMockLink, titleVisibility: .visible) {
                Button("Approve access to \(country == "US" ? "American Express (mock)" : "CIBC (mock)")") { Task { await useTestBank() } }
            } message: {
                Text("The service is in mock mode, so Plaid Link is simulated with synthetic data.")
            }
        }
    }

    private func start() async {
        working = true; error = nil
        defer { working = false }
        do {
            let token = try await store.client.linkToken(country: country)
            if token.environment == "mock" { showMockLink = true; return }
            link.open(token: token.linkToken,
                      onSuccess: { publicToken in Task { await finish(publicToken: publicToken) } },
                      onExit: { message in error = message })
        } catch { self.error = error.localizedDescription }
    }

    private func useTestBank() async {
        working = true; error = nil
        defer { working = false }
        do { await finish(publicToken: try await store.client.testPublicToken(country: country)) }
        catch { self.error = error.localizedDescription }
    }

    private func finish(publicToken: String) async {
        working = true
        defer { working = false }
        do {
            let connectionID = try await store.completeLink(publicToken: publicToken, country: country, clientRequestID: clientRequestID)
            dismiss()
            // Open account mapping only after this sheet is gone (one sheet at a time).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                store.pendingMappingConnectionID = connectionID
            }
        } catch {
            self.error = "\(error.localizedDescription) You can retry safely."
        }
    }
}

// MARK: - Plaid Link update mode (reconnect an existing Item)

struct ReauthView: View {
    @SwiftUI.Environment(Store.self) private var store
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let connectionID: String
    var billAccess = false
    @State private var linkToken: String?
    @State private var link = LinkPresenter()
    @State private var mock = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if billAccess {
                        Text("Allow Plaid to read your card’s statement due date for payment alerts.")
                    } else {
                        Text("Your bank needs you to sign in again. Your existing card history is kept.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(mock ? "Approve (mock bank)" : "Continue to Plaid") {
                        if mock { finish() }
                        else if let linkToken {
                            link.open(token: linkToken,
                                      onSuccess: { _ in finish() },
                                      onExit: { message in error = message })
                        }
                    }
                    .disabled(linkToken == nil && !mock)
                }
            }
            .navigationTitle(billAccess ? "Authorize bill dates" : "Reconnect")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if !billAccess { store.reauthConnectionID = nil }
                        dismiss()
                    }
                }
            }
            .task {
                do {
                    let t = try await store.client.linkToken(country: (try? store.repo?.connection(connectionID))??.country ?? "US",
                                                            connectionID: connectionID, billAccess: billAccess)
                    mock = t.environment == "mock"
                    linkToken = t.linkToken
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func finish() {
        Task { @MainActor in
            if billAccess {
                dismiss()
                await store.refreshBillAlerts(force: true)
            } else {
                await store.completeReauth(connectionID: connectionID)
                dismiss()
            }
        }
    }
}


// MARK: - Map linked accounts to cards (design §3)

struct MapAccountsView: View {
    @SwiftUI.Environment(Store.self) private var store
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let connectionID: String
    @State private var accounts: [SourceAccount] = []
    @State private var include: [String: Bool] = [:]
    @State private var product: [String: String] = [:]
    @State private var nickname: [String: String] = [:]
    @State private var institution: String?
    @State private var confirming = false

    private var creditAccounts: [SourceAccount] { accounts.filter(\.needsMapping) }
    private var others: [SourceAccount] { accounts.filter { !$0.isCreditCard } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This bank is already connected. Choose the card product for each account; accounts you switch off are hidden and won’t ask again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(creditAccounts) { a in
                    Section {
                        Toggle(isOn: includeBinding(a.id)) {
                            VStack(alignment: .leading) {
                                Text(a.name)
                                Text("•••• \(a.mask ?? "––––") · \(a.currency ?? "unknown currency")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if include[a.id] ?? true {
                            ProductPicker(selection: productBinding(a), market: a.currency.flatMap(CurrencyCode.init(rawValue:)),
                                          bank: Catalog.issuer(matching: institution, market: a.currency.flatMap(CurrencyCode.init(rawValue:))))
                            TextField("Nickname", text: nicknameBinding(a))
                        }
                    }
                }
                if creditAccounts.isEmpty {
                    Section { Text("No unassigned credit-card accounts on this connection.").foregroundStyle(.secondary) }
                }
                if !others.isEmpty {
                    Section("Not card accounts — ignored") {
                        ForEach(others) { a in
                            LabeledContent(a.name, value: "\(a.subtype ?? a.type) •••• \(a.mask ?? "")")
                        }
                    }
                }
            }
            .navigationTitle("Map accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { store.pendingMappingConnectionID = nil; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        guard !confirming else { return }
                        confirming = true
                        let mapping = creditAccounts.filter { include[$0.id] ?? true }.map { a in
                            let pid = product[a.id] ?? suggestedProduct(a)
                            let rawName = (nickname[a.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            return (account: a, productID: pid, nickname: rawName.isEmpty ? Catalog.product(pid).name : rawName)
                        }
                        let hidden = creditAccounts.filter { !(include[$0.id] ?? true) }
                        Task {
                            await store.confirmMapping(connectionID: connectionID, mapping, hide: hidden)
                            confirming = false
                            dismiss()
                        }
                    }
                    .disabled(creditAccounts.isEmpty || confirming)
                }
            }
            .task {
                accounts = (try? store.repo?.accounts(connection: connectionID)) ?? []
                institution = (try? store.repo?.connection(connectionID))??.institution
            }
        }
    }

    private func includeBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { include[id] ?? true }, set: { include[id] = $0 })
    }
    private func productBinding(_ a: SourceAccount) -> Binding<String> {
        Binding(get: { product[a.id] ?? suggestedProduct(a) }, set: { product[a.id] = $0; nickname[a.id] = Catalog.product($0).name })
    }
    private func nicknameBinding(_ a: SourceAccount) -> Binding<String> {
        Binding(get: { nickname[a.id] ?? Catalog.product(product[a.id] ?? suggestedProduct(a)).name }, set: { nickname[a.id] = $0 })
    }

    /// Suggests a catalog product from the account name, institution and currency; the owner confirms.
    private func suggestedProduct(_ a: SourceAccount) -> String {
        Catalog.suggest(accountName: a.name, institution: institution, currency: a.currency).id
    }
}

/// Product picker: a row that opens a searchable list grouped by issuer, filtered to the account's market.
struct ProductPicker: View {
    @Binding var selection: String
    let market: CurrencyCode?
    /// Bank to pre-filter by (e.g. the linked institution); the owner can clear it.
    var bank: String? = nil

    var body: some View {
        NavigationLink {
            ProductListView(selection: $selection, market: market,
                            initialBank: bank ?? Catalog.product(selection).issuer)
        } label: {
            LabeledContent("Card product") {
                Text(Catalog.product(selection).displayName).multilineTextAlignment(.trailing)
            }
        }
    }
}

struct ProductListView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let market: CurrencyCode?
    @State private var bank: String?
    @State private var query = ""
    @State private var segment = 0 // 0 all, 1 personal, 2 business

    init(selection: Binding<String>, market: CurrencyCode?, initialBank: String? = nil) {
        _selection = selection
        self.market = market
        let banks = Catalog.issuers(market: market)
        _bank = State(initialValue: initialBank.flatMap { b in banks.contains(b) && b != "Other" ? b : nil })
    }

    private var banks: [String] { Catalog.issuers(market: market) }

    /// Bank filter narrows the list; the search box matches product names (and issuer when no bank is chosen).
    private var groups: [(issuer: String, products: [CardProduct])] {
        let q = Catalog.normalize(query)
        return Catalog.grouped(market: market).compactMap { g in
            guard bank == nil || g.issuer == bank || g.issuer == "Other" else { return nil }
            let items = g.products.filter { p in
                (segment == 0 || (segment == 2) == p.isBusiness)
                && (q.isEmpty
                    || Catalog.normalize(p.name).contains(q)
                    || (bank == nil && Catalog.normalize(p.issuer).contains(q))
                    || p.matchKeywords.contains { $0.contains(q) })
            }
            return items.isEmpty ? nil : (g.issuer, items)
        }
    }

    private var resultCount: Int { groups.reduce(0) { $0 + $1.products.count } }

    var body: some View {
        List {
            Section {
                Picker("Bank", selection: $bank) {
                    Text("All banks").tag(String?.none)
                    ForEach(banks.filter { $0 != "Other" }, id: \.self) { b in
                        Text("\(b) (\(Catalog.products(market: market).filter { $0.issuer == b }.count))").tag(Optional(b))
                    }
                }
                .pickerStyle(.menu)
                Picker("Type", selection: $segment) {
                    Text("All").tag(0); Text("Personal").tag(1); Text("Business").tag(2)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("\(resultCount) of \(Catalog.products(market: market).count) products · catalog v\(Catalog.version). Not listed? Choose Other.")
            }
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(groups, id: \.issuer) { group in
                Section(group.issuer) {
                    ForEach(group.products) { p in
                        Button {
                            selection = p.id
                            dismiss()
                        } label: {
                            HStack {
                                CardThumbnail(product: p)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundStyle(.primary)
                                    Text("\(p.network) · \(p.annualFee.isZero ? "No annual fee" : p.annualFee.short)\(p.isBusiness ? " · Business" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.id == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .accessibilityAddTraits(p.id == selection ? .isSelected : [])
                    }
                }
            }
        }
        .navigationTitle("Card product")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: bank.map { "Search \($0) cards" } ?? "Search card or bank")
    }
}

