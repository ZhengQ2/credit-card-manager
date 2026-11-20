import SwiftUI
import AuthenticationServices

// MARK: - Sign in

/// Account sign-in with an emailed code, password, or passkey.
struct SignInView: View {
    @SwiftUI.Environment(Store.self) private var store
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.authorizationController) private var authorizationController
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var secondFactor: ServiceClient.SecondFactor?
    @State private var authenticatorCode = ""
    @State private var useRecoveryCode = false
    @State private var passkeyAvailable = false
    @State private var passwordAvailable = false
    @State private var usePassword = false
    @State private var password = ""
    @State private var environment = ""
    @State private var working = false
    @State private var error: String?
    @State private var choosingBills = false
    @State private var serviceURL = ServiceClient.defaultBaseURL.absoluteString
    @FocusState private var focus: Field?
    private enum Field { case email, code, password, authenticator }

    private var url: URL? {
        guard let u = URL(string: serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)), u.host != nil else { return nil }
        return u
    }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
              if choosingBills {
                Section {
                    Text("Card Ledger can use due dates your bank shares to schedule payment reminders on this iPhone. Each bank asks for permission before sharing bill dates.")
                    Button("Set up bill alerts") { Task { await chooseBillAlerts(true) } }.disabled(working)
                    Button("Skip bill alerts") { Task { await chooseBillAlerts(false) } }.disabled(working)
                } header: {
                    Text("Automatic bill payment alerts")
                } footer: {
                    Text("Automatic due dates and payment reminders stay off if you skip or decline iOS notifications. You can turn them on later in Settings.")
                }
                if let message = store.billNotifications.message ?? store.billRefreshMessage {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
              } else {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress).textContentType(usePassword ? .username : .emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .disabled(codeSent || secondFactor != nil || working)
                    if secondFactor != nil {
                        TextField(useRecoveryCode ? "Recovery code" : "Authenticator code", text: $authenticatorCode)
                            .keyboardType(useRecoveryCode ? .asciiCapable : .numberPad)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.title3.monospacedDigit())
                            .focused($focus, equals: .authenticator)
                    } else if usePassword {
                        SecureField("Password", text: $password)
                            .textContentType(.password).focused($focus, equals: .password)
                            .onSubmit { Task { await signInWithPassword() } }
                    } else if codeSent {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .font(.title3.monospacedDigit())
                            .focused($focus, equals: .code)
                            .onChange(of: code) { _, v in
                                let digits = String(v.filter(\.isNumber).prefix(6))
                                if digits != v { code = digits }
                                if digits.count == 6 { Task { await verify() } }
                            }
                    }
                } footer: {
                    Text(secondFactor != nil
                         ? (useRecoveryCode ? "Enter one of the recovery codes you saved." : "Enter the current code from your authenticator app.")
                         : codeSent
                         ? "If \(trimmedEmail) has an account or an invitation, a code is on its way. It expires in 10 minutes."
                         : "Card Ledger uses your email to identify your account and deliver sign-in codes. Linked bank sync and automatic bill dates require an account. Manual cards and statement import are available without signing in.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    if secondFactor != nil {
                        Button("Verify and sign in") { Task { await verifySecondFactor() } }
                            .disabled(working || authenticatorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(useRecoveryCode ? "Use an authenticator code" : "Use a recovery code") {
                            useRecoveryCode.toggle()
                            authenticatorCode = ""
                        }.disabled(working)
                        Button("Start over") { resetSignIn() }.disabled(working)
                    } else if codeSent {
                        Button { Task { await verify() } } label: {
                            HStack { Text("Sign in"); if working { Spacer(); ProgressView() } }
                        }
                        .disabled(working || code.count != 6)
                        Button("Send a new code") { Task { await send() } }.disabled(working)
                        Button("Use a different email") { resetSignIn() }.disabled(working)
                    } else if usePassword {
                        Button("Sign in") { Task { await signInWithPassword() } }
                            .disabled(working || password.isEmpty || !trimmedEmail.contains("@"))
                        Button("Use an email code") { resetSignIn() }.disabled(working)
                    } else {
                        Button { Task { await send() } } label: {
                            HStack { Text("Email me a code"); if working { Spacer(); ProgressView() } }
                        }
                        .disabled(working || !trimmedEmail.contains("@") || url == nil)
                        if passwordAvailable {
                            Button("Use a password") {
                                usePassword = true
                                error = nil
                                focus = trimmedEmail.isEmpty ? .email : .password
                            }.disabled(working)
                        }
                        if passkeyAvailable {
                            Button("Sign in with a passkey", systemImage: "person.badge.key") { Task { await signInWithPasskey() } }
                                .disabled(working)
                        }
                    }
                }
                #if DEBUG
                Section {
                    TextField("Service URL", text: $serviceURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(codeSent || secondFactor != nil || usePassword || working)
                } header: { Text("Developer") } footer: {
                    Text("Debug builds only. Use http://127.0.0.1:8787 for the mock service in the simulator.")
                }
                #endif
              }
            }
            .navigationTitle(choosingBills ? "Set up your account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(choosingBills || working)
            .toolbar {
                if !choosingBills {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                }
            }
            .onAppear { focus = .email }
            .task(id: url) {
                passkeyAvailable = false
                passwordAvailable = false
                guard let url else { return }
                let health = try? await store.client.health(baseURL: url)
                guard !Task.isCancelled else { return }
                passwordAvailable = health?.signIn?.contains("password") == true
                passkeyAvailable = AccountPasskeys.isAvailable(for: url) && health?.signIn?.contains("passkey") == true
            }
        }
    }

    private func send() async {
        guard let url, !working else { return }
        working = true; error = nil
        defer { working = false }
        do {
            environment = try await store.startSignIn(url: url, email: trimmedEmail)
            codeSent = true; code = ""
            focus = .code
        } catch {
            self.error = accountAuthMessage(for: error)
        }
    }

    private func signInWithPassword() async {
        guard let url, !password.isEmpty, !working, trimmedEmail.contains("@") else { return }
        working = true; error = nil
        defer { working = false; password = "" }
        do {
            environment = try await store.client.health(baseURL: url).environment
            if let challenge = try await store.client.signInWithPassword(baseURL: url, environment: environment,
                                                                         email: trimmedEmail, password: password) {
                secondFactor = challenge
                focus = .authenticator
            } else {
                store.didSignIn()
                finishSignIn()
            }
        } catch {
            self.error = accountAuthMessage(for: error)
        }
    }

    private func verify() async {
        guard let url, code.count == 6, !working else { return }
        working = true; error = nil
        defer { working = false }
        do {
            if let challenge = try await store.completeSignIn(url: url, environment: environment, email: trimmedEmail, code: code) {
                secondFactor = challenge
                code = ""
                focus = .authenticator
            } else {
                finishSignIn()
            }
        } catch {
            self.error = accountAuthMessage(for: error)
            code = ""
        }
    }

    private func verifySecondFactor() async {
        guard let url, let secondFactor, !working else { return }
        working = true; error = nil
        defer { working = false }
        do {
            try await store.client.completeSecondFactor(baseURL: url, environment: environment, id: secondFactor.id, code: authenticatorCode)
            store.didSignIn()
            finishSignIn()
        } catch {
            authenticatorCode = ""
            self.error = accountAuthMessage(for: error)
        }
    }

    private func signInWithPasskey() async {
        guard let url, !working else { return }
        working = true; error = nil
        focus = nil
        defer { working = false }
        do {
            let health = try await store.client.health(baseURL: url)
            let challenge = try await store.client.startPasskeySignIn(baseURL: url)
            let credential = try await AccountPasskeys.assertion(challenge, for: url, using: authorizationController)
            try await store.client.completePasskeySignIn(baseURL: url, environment: health.environment,
                                                         id: challenge.id, credential: credential)
            store.didSignIn()
            finishSignIn()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            self.error = accountAuthMessage(for: error)
        }
    }

    private func finishSignIn() {
        focus = nil
        if store.needsBillAlertChoice { choosingBills = true }
        else { dismiss() }
    }

    private func chooseBillAlerts(_ enabled: Bool) async {
        guard !working else { return }
        working = true
        defer { working = false }
        if await store.setBillAlertsEnabled(enabled) { dismiss() }
    }

    private func resetSignIn() {
        codeSent = false
        code = ""
        secondFactor = nil
        authenticatorCode = ""
        useRecoveryCode = false
        usePassword = false
        password = ""
        error = nil
        focus = .email
    }
}

// MARK: - Connect a bank with Plaid Link

struct ConnectBankView: View {
    @SwiftUI.Environment(Store.self) private var store
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var country = "US"
    @State private var historyMonths = 12
    @State private var link = LinkPresenter()
    @State private var showMockLink = false
    @State private var working = false
    @State private var error: String?
    /// Reused across retries so the service deduplicates the exchange.
    @State private var clientRequestID = UUID().uuidString
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                if !store.isSignedIn {
                    Section {
                        Text("Sign in to your Card Ledger account to connect banks.")
                        Button("Sign in…") { showSignIn = true }
                    }
                } else {
                    Section {
                        Picker("Bank country", selection: $country) {
                            Text("United States").tag("US")
                            Text("Canada").tag("CA")
                        }
                        .pickerStyle(.segmented)
                        Picker("Transaction history", selection: $historyMonths) {
                            Text("Last 12 months").tag(12)
                            Text("Last 24 months").tag(24)
                        }
                    } footer: {
                        Text("Choose which credit cards to share in Plaid. Card Ledger uses up to \(historyMonths) months of their transactions for spending and benefits. The service passes the transactions to your encrypted ledger on this iPhone. Bill dates have a separate approval in Settings.")
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
                        Text("Skipping Plaid leaves automatic transaction sync and bank-provided bill dates unavailable for this bank. You can add cards and import statements manually.")
                    }
                }
            }
            .navigationTitle("Connect a bank")
            .sheet(isPresented: $showSignIn) { SignInView() }
            .plaidLinkSheet(link)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) } }
            .confirmationDialog("Mock bank", isPresented: $showMockLink, titleVisibility: .visible) {
                Button("Approve access to \(country == "US" ? "American Express (mock)" : "CIBC (mock)")") { Task { await useTestBank() } }
            } message: {
                Text("The service is in mock mode, so Plaid Link is simulated with synthetic data.")
            }
        }
    }

    private func start() async {
        guard !working else { return }
        working = true; error = nil
        defer { working = false }
        let selectedCountry = country
        do {
            let token = try await store.client.linkToken(country: selectedCountry, historyDays: historyMonths == 24 ? 730 : 365)
            if token.environment == "mock" { showMockLink = true; return }
            link.open(token: token.linkToken,
                      onSuccess: { publicToken in Task { await finish(publicToken: publicToken, country: selectedCountry) } },
                      onExit: { message in error = message })
        } catch { self.error = error.localizedDescription }
    }

    private func useTestBank() async {
        working = true; error = nil
        defer { working = false }
        let selectedCountry = country
        do { await finish(publicToken: try await store.client.testPublicToken(country: selectedCountry), country: selectedCountry) }
        catch { self.error = error.localizedDescription }
    }

    private func finish(publicToken: String, country: String) async {
        working = true
        defer { working = false }
        do {
            let connectionID = try await store.completeLink(publicToken: publicToken, country: country, clientRequestID: clientRequestID)
            if store.billAlertsEnabled { store.billSetupAfterMappingID = connectionID }
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
    @State private var link = LinkPresenter()
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if billAccess {
                        Text("Plaid may request access to credit card liabilities. Card Ledger uses the next due dates for your added cards to schedule alerts on this iPhone. You can withdraw this access in Settings.")
                    } else {
                        Text("Your bank needs you to sign in again. Your existing card history is kept.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(billAccess ? "Authorize bill dates in Plaid" : "Continue to Plaid") { Task { await start() } }
                        .disabled(working)
                    if working { ProgressView() }
                } footer: {
                    Text(billAccess
                         ? "If you skip, automatic due dates and payment reminders stay unavailable for these cards."
                         : "Skipping leaves automatic sync paused until you reconnect this bank.")
                }
            }
            .navigationTitle(billAccess ? "Authorize bill dates" : "Reconnect")
            .plaidLinkSheet(link)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(billAccess ? "Skip bill dates" : "Cancel") {
                        if !billAccess { store.reauthConnectionID = nil }
                        dismiss()
                    }.disabled(working)
                }
            }
        }
    }

    private func start() async {
        guard !working, !billAccess || store.billAlertsEnabled else { return }
        error = nil
        working = true
        do {
            let country = try store.repo?.connection(connectionID)?.country ?? "US"
            let token = try await store.client.linkToken(country: country, connectionID: connectionID, billAccess: billAccess)
            working = false
            if token.environment == "mock" {
                await finish(consentID: token.billConsentId)
            } else {
                link.open(token: token.linkToken,
                          onSuccess: { _ in Task { await finish(consentID: token.billConsentId) } },
                          onExit: { message in error = message })
            }
        } catch {
            working = false
            self.error = error.localizedDescription
        }
    }

    private func finish(consentID: String?) async {
        working = true
        defer { working = false }
        do {
            if billAccess {
                guard store.billAlertsEnabled else { return }
                guard let consentID else { throw ServiceError.server(code: "bill_consent_expired", retryable: false) }
                try await store.client.confirmBillAccess(connectionID: connectionID, consentID: consentID)
                dismiss()
                await store.refreshBillAlerts(force: true)
            } else {
                await store.completeReauth(connectionID: connectionID)
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
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
    @State private var configureBills = false

    private var creditAccounts: [SourceAccount] { accounts.filter(\.needsMapping) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose which credit cards to sync and confirm their card products. Cards you skip are hidden, and automatic transaction sync and bill dates are unavailable for them.")
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
                        let confirmed = store.confirmMapping(connectionID: connectionID, mapping, hide: hidden)
                        confirming = false
                        if confirmed {
                            if store.billSetupAfterMappingID == connectionID {
                                store.billSetupAfterMappingID = nil
                                configureBills = store.billAlertsEnabled && !mapping.isEmpty
                            }
                            if !configureBills { closeMapping() }
                        }
                    }
                    .disabled(creditAccounts.isEmpty || confirming)
                }
            }
            .task {
                accounts = (try? store.repo?.accounts(connection: connectionID)) ?? []
                institution = (try? store.repo?.connection(connectionID))??.institution
            }
            .sheet(isPresented: $configureBills, onDismiss: closeMapping) {
                ReauthView(connectionID: connectionID, billAccess: true)
            }
        }
    }

    private func closeMapping() {
        store.pendingMappingConnectionID = nil
        dismiss()
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

