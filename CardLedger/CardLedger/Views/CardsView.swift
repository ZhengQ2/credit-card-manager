import SwiftUI

struct CardsView: View {
    @Environment(Store.self) private var store
    @State private var connecting = false
    @State private var addingManually = false
    @State private var importingPDF = false
    @State private var importingCSV = false

    var body: some View {
        NavigationStack {
            List {
                Section("Wallet summary") {
                    HStack {
                        SummaryTile(value: "\(store.cards.count)", label: "Cards")
                        Divider()
                        SummaryTile(value: "\(store.fiveTwentyFourCount)/5", label: "Chase 5/24")
                        Divider()
                        VStack(spacing: 2) {
                            Text(store.annualFees(.usd).short).font(.callout.weight(.semibold).monospacedDigit())
                            Text(store.annualFees(.cad).short).font(.callout.weight(.semibold).monospacedDigit())
                            Text("Annual fees").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                }

                if store.mode == .sample {
                    Section {
                        Button { connecting = true } label: { Label("Connect a bank with Plaid", systemImage: "link.badge.plus") }
                        Button { importingPDF = true } label: { Label("Import a PDF statement", systemImage: "doc.richtext") }
                        Button { importingCSV = true } label: { Label("Import CSV activity", systemImage: "tablecells") }
                    } footer: {
                        Text("These cards are sample data. They disappear once you link or add your first card.")
                    }
                }
                let toMap = store.connectionsNeedingMapping
                if !toMap.isEmpty || store.hiddenAccountCount > 0 {
                    Section {
                        ForEach(toMap, id: \.connection.id) { item in
                            Button { store.pendingMappingConnectionID = item.connection.id } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(item.connection.institution): \(item.accounts.count) card account\(item.accounts.count == 1 ? "" : "s") not added")
                                            .foregroundStyle(.primary)
                                        Text(item.accounts.map { "•••• \($0.mask ?? "––––")" }.joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "plus.rectangle.on.rectangle") }
                            }
                            .swipeActions {
                                Button("Hide") { store.hideAccounts(item.accounts) }.tint(.gray)
                            }
                        }
                        if store.hiddenAccountCount > 0 {
                            Button("Show \(store.hiddenAccountCount) hidden account\(store.hiddenAccountCount == 1 ? "" : "s")") { store.unhideAccounts() }
                                .font(.callout)
                        }
                    } header: {
                        Text("Already linked, not yet added")
                    } footer: {
                        if !toMap.isEmpty {
                            Text("These banks are already connected; no new sign-in is needed. Tap to choose the card product, or swipe to hide accounts you don't want to track.")
                        }
                    }
                }
                ForEach(CurrencyCode.allCases.filter { c in store.cards.contains { Catalog.product($0.productID).market == c } }) { currency in
                    Section(currency == .usd ? "U.S. cards" : "Canadian cards") {
                        ForEach(store.cards.filter { Catalog.product($0.productID).market == currency }) { card in
                            NavigationLink(value: Route.card(card.id)) { CardRow(card: card) }
                        }
                    }
                }
            }
            .navigationTitle("Cards")
            .sheet(isPresented: $connecting) { ConnectBankView() }
            .sheet(isPresented: $addingManually) { AddCardView() }
            .sheet(isPresented: $importingPDF) { PDFImportView() }
            .sheet(isPresented: $importingCSV) { PDFImportView(format: .csv) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Connect with Plaid", systemImage: "link") { connecting = true }
                        Button("Import PDF statement", systemImage: "doc.richtext") { importingPDF = true }
                        Button("Import CSV activity", systemImage: "tablecells") { importingCSV = true }
                        Button("Add manually", systemImage: "square.and.pencil") { addingManually = true }
                    } label: { Image(systemName: "plus").accessibilityLabel("Add card") }
                }
            }
            .withRoutes()
        }
    }
}

struct SummaryTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct CardRow: View {
    let card: Card

    var body: some View {
        let product = Catalog.product(card.productID)
        HStack(spacing: 12) {
            CardChip(card: card)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.nickname).font(.body.weight(.semibold))
                Text("\(product.issuer) · •••• \(card.mask ?? "––––") · \(product.market.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                ConnectionLabel(state: card.connection)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionLabel: View {
    let state: ConnectionState

    var body: some View {
        switch state {
        case .plaid: Label(state.label, systemImage: "link").font(.caption).foregroundStyle(.green)
        case .csv: Label(state.label, systemImage: "doc.text").font(.caption).foregroundStyle(.blue)
        case .pdf: Label(state.label, systemImage: "doc.richtext").font(.caption).foregroundStyle(.indigo)
        case .manual: Label(state.label, systemImage: "square.and.pencil").font(.caption).foregroundStyle(.secondary)
        case .reauthRequired, .disconnectPending: Label(state.label, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .disconnected: Label(state.label, systemImage: "link.badge.plus").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CardDetailView: View {
    @Environment(Store.self) private var store
    let cardID: String
    @State private var confirmDisconnect = false
    @State private var confirmDelete = false
    @State private var editingRenewal = false
    @State private var importingPDF = false
    @State private var importingCSV = false
    @State private var changingProduct = false
    @State private var renewalDraft = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let card = store.card(cardID) {
            content(card)
        } else {
            ContentUnavailableView("Card removed", systemImage: "creditcard.trianglebadge.exclamationmark",
                                   description: Text("This card is no longer on this iPhone."))
        }
    }

    @ViewBuilder
    private func content(_ card: Card) -> some View {
        let product = Catalog.product(card.productID)
        let program = Catalog.program(product.programID)
        List {
            Section {
                CardArt(card: card)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Connection") {
                HStack {
                    ConnectionLabel(state: card.connection)
                    Spacer()
                    if card.connection.needsReauth {
                        Button("Reconnect") { store.reconnect(card.id) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                if let s = card.lastSync { LabeledContent("Last local sync", value: s.relativeAge) }
                LabeledContent("History covered from", value: Day.format(card.historyStart))
                OpenDateSection(card: card)
                Button {
                    importingPDF = true
                } label: {
                    Label("Import PDF statement", systemImage: "doc.richtext")
                }
                Button {
                    importingCSV = true
                } label: {
                    Label("Import CSV activity", systemImage: "tablecells")
                }
            }

            StatementBillSection(card: card)

            Section {
                Button { changingProduct = true } label: {
                    LabeledContent("Card product") {
                        HStack(spacing: 8) {
                            Text(product.displayName).multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .tint(.primary)
                .accessibilityHint("Choose a different card product")
            } header: {
                Text("Card type")
            } footer: {
                Text("Choose a different product if this card was matched to the wrong one. Earn rates, credits, fees and free night awards follow the new product. Transactions and dates stay.")
            }

            WelcomeOfferSection(card: card)

            CertificatesAndMembershipsSection(card: card)

            Section("Fees") {
                LabeledContent("Annual fee", value: product.annualFee.formatted)
                LabeledContent("Credits used, last 12 months", value: store.creditsRedeemed(for: card).formatted)
                let offerRows = store.offerCredits(for: card)
                if !offerRows.isEmpty {
                    DisclosureGroup {
                        ForEach(offerRows) { t in
                            NavigationLink(value: Route.transaction(t.id)) {
                                LabeledContent(t.merchant, value: Day.format(t.posted, .dateTime.month(.abbreviated).day()))
                            }
                        }
                    } label: {
                        LabeledContent {
                            Text(store.offersEarned(for: card).formatted)
                        } label: {
                            Text("Offers earned")
                            Text("\(offerRows.count) card-linked offer\(offerRows.count == 1 ? "" : "s"), last 12 months\(store.countOffersInFee ? "" : " · not in effective fee")")
                        }
                    }
                }
                LabeledContent("Effective fee") {
                    VStack(alignment: .trailing) {
                        Text(store.effectiveFee(card).formatted).fontWeight(.semibold)
                        if store.offers(for: card.id).contains(where: { $0.kind == .feeWaiver && store.today < $0.end }) {
                            Text("First-year fee waived").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                if let r = store.renewal(card) {
                    LabeledContent("Renewal") {
                        VStack(alignment: .trailing) {
                            Text(r.precision == .month ? Day.format(r.date, .dateTime.month(.wide).year()) : Day.format(r.date))
                            Text(r.source.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Change renewal date") {
                        renewalDraft = Day.toLocal(r.date)
                        editingRenewal = true
                    }
                    .font(.callout)
                } else {
                    Button("Add a renewal date") {
                        renewalDraft = Day.toLocal(Day.addMonths(12, to: card.openedOn))
                        editingRenewal = true
                    }
                }
                LabeledContent("Foreign transaction fee", value: product.foreignTransactionFee == 0 ? "None" : "\((product.foreignTransactionFee * 100).formatted())%")
            }

            let current = store.benefits.periods.filter { $0.card.id == card.id && $0.isCurrent(today: store.today) }
            if !current.isEmpty {
                Section("Benefits this period") {
                    ForEach(current) { p in
                        NavigationLink(value: Route.period(p.id)) { DeadlineRow(period: p) }
                    }
                }
            }

            Section {
                ForEach(Array(product.earnRules.enumerated()), id: \.offset) { _, rule in
                    HStack(alignment: .top) {
                        Text("\(rule.multiplier.formatted())×").font(.callout.weight(.semibold).monospacedDigit()).frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.categories.map(\.title).sorted().joined(separator: ", "))
                            if let note = rule.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                HStack {
                    Text("\(product.baseMultiplier.formatted())×").font(.callout.weight(.semibold).monospacedDigit()).frame(width: 44, alignment: .leading)
                    Text("Everything else")
                }
            } header: {
                Text("Earning · \(program.name)")
            }

            if !product.perks.isEmpty {
                Section("Perks") {
                    ForEach(product.perks, id: \.self) { Text($0) }
                }
            }

            Section {
                LabeledContent("Catalog", value: "v\(Catalog.version)")
                LabeledContent("Full terms review", value: product.verified ? "Checked \(product.checkedOn ?? "")" : "Pending")
                Link(destination: product.sourceURL) { Label("Product terms and information", systemImage: "safari") }
            } header: { Text("Source") } footer: {
                Text(product.verified ? "Values were checked against the issuer's terms on the date shown." : Catalog.disclaimer)
                if let notes = product.notes { Text(notes) }
            }

            if store.unknownCurrencyCount > 0 {
                Section {
                    Label("\(store.unknownCurrencyCount) transaction\(store.unknownCurrencyCount == 1 ? "" : "s") across your ledger have an unsupported or unofficial currency and are not counted.",
                          systemImage: "questionmark.circle")
                }
            }
            Section {
                if card.connectionID != nil, !isDisconnected(card) {
                    Button(isPending(card) ? "Retry disconnect" : "Disconnect bank feed") { confirmDisconnect = true }
                }
                Button("Delete local history", role: .destructive) { confirmDelete = true }
                    .disabled(store.mode == .sample)
            } footer: {
                Text("Disconnecting revokes Plaid access and keeps local history. Deleting removes this card's transactions, matches, and reminders.")
            }
        }
        .navigationTitle(card.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect \(card.nickname)?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await store.disconnect(cardID: card.id) } }
        } message: {
            let siblings = store.cards.filter { $0.connectionID == card.connectionID }.map(\.nickname)
            Text("Revokes Plaid access for this bank login\(siblings.count > 1 ? ", affecting " + siblings.joined(separator: ", ") : ""). Local history stays on this iPhone.")
        }
        .confirmationDialog("Delete \(card.nickname) history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete history", role: .destructive) {
                dismiss() // leave the detail screen; the card no longer exists after deletion
                store.deleteHistory(cardID: card.id)
            }
        } message: {
            let count = store.transactions.filter { $0.cardID == card.id }.count
            let stillLinked = card.connectionID != nil && {
                if case .disconnected = card.connection { return false } else { return true }
            }()
            Text("Deletes this card, its \(count) transactions, benefit matches, and scheduled reminders from this iPhone. This cannot be undone."
                 + (stillLinked ? " The bank account stays linked but is hidden; use \"Show hidden accounts\" in Cards to add it back. Disconnect to stop Plaid access." : ""))
        }
        .sheet(isPresented: $editingRenewal) {
            NavigationStack {
                Form {
                    DatePicker("Next renewal", selection: $renewalDraft, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    if card.renewal != nil {
                        Section {
                            Button("Clear custom renewal date", role: .destructive) {
                                store.setRenewal(card.id, date: nil)
                                editingRenewal = false
                            }
                        }
                    }
                }
                .navigationTitle("Renewal date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingRenewal = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            store.setRenewal(card.id, date: Day.fromLocal(renewalDraft))
                            editingRenewal = false
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $importingPDF) {
            PDFImportView(preselectedCardID: store.mode == .live ? card.id : nil)
        }
        .sheet(isPresented: $changingProduct) {
            NavigationStack {
                ProductListView(selection: Binding(get: { card.productID },
                                                   set: { store.changeProduct(card.id, to: $0); changingProduct = false }),
                                market: product.market, initialBank: product.issuer)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changingProduct = false } } }
            }
        }
        .sheet(isPresented: $importingCSV) {
            PDFImportView(preselectedCardID: store.mode == .live ? card.id : nil, format: .csv)
        }
    }
}

private func isDisconnected(_ c: Card) -> Bool { if case .disconnected = c.connection { true } else { false } }
private func isPending(_ c: Card) -> Bool { if case .disconnectPending = c.connection { true } else { false } }

/// Add a card without a bank feed, chosen from the catalog.
struct AddCardView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var market: CurrencyCode = .usd
    @State private var productID = "amex-platinum-us"
    @State private var nickname = ""
    @State private var mask = ""
    @State private var openedOn = Day.toLocal(Day.addMonths(-12, to: Day.today))
    @State private var hasRenewal = false
    @State private var renewal = Day.toLocal(Day.addMonths(1, to: Day.today))

    private var product: CardProduct { Catalog.product(productID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Market", selection: $market) {
                        Text("United States").tag(CurrencyCode.usd)
                        Text("Canada").tag(CurrencyCode.cad)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: market) { _, m in
                        productID = Catalog.products(market: m).first { $0.issuer != "Other" }?.id ?? productID
                    }
                    ProductPicker(selection: $productID, market: market)
                }
                Section {
                    TextField(product.name, text: $nickname)
                    TextField("Last digits (optional)", text: $mask)
                        .keyboardType(.numberPad)
                        .onChange(of: mask) { _, v in
                            let digits = String(v.filter(\.isNumber).prefix(5))
                            if digits != v { mask = digits }
                        }
                    DatePicker("Opened", selection: $openedOn, displayedComponents: .date)
                    Toggle("I know the renewal date", isOn: $hasRenewal)
                    if hasRenewal { DatePicker("Renewal", selection: $renewal, displayedComponents: .date) }
                } footer: {
                    Text("Manual cards have no bank feed; you can link the bank later. Never enter the full card number.")
                }
                Section("This product") {
                    LabeledContent("Annual fee", value: product.annualFee.formatted)
                    LabeledContent("Rewards", value: Catalog.program(product.programID).name)
                    if !product.benefits.isEmpty {
                        LabeledContent("Tracked credits", value: "\(product.benefits.count)")
                    }
                    if !product.verified {
                        Text("Catalog values are unverified starting points.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.addManualCard(nickname: trimmed.isEmpty ? product.name : trimmed, productID: productID,
                                            mask: (4...5).contains(mask.count) ? mask : nil, openedOn: Day.fromLocal(openedOn),
                                            renewal: hasRenewal ? Day.fromLocal(renewal) : nil)
                        dismiss()
                    }
                }
            }
        }
    }
}
