import SwiftUI

struct ActivityView: View {
    @Environment(Store.self) private var store
    @State private var search = ""
    @State private var kind: TransactionKind?
    @State private var currency: CurrencyCode?

    private var filtered: [Transaction] {
        store.effectiveTransactions.filter { t in
            (store.activityCardID == nil || t.cardID == store.activityCardID)
            && (store.activityCategory == nil || (t.category == store.activityCategory && (t.kind == .purchase || t.kind == .refund)))
            && (kind == nil || t.kind == kind)
            && (currency == nil || t.amount.currency == currency)
            && (search.isEmpty || t.merchant.localizedCaseInsensitiveContains(search) || t.originalDescription.localizedCaseInsensitiveContains(search))
        }
    }

    private var grouped: [(Date, [Transaction])] {
        Dictionary(grouping: filtered) { Day.startOfMonth($0.posted) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.posted > $1.posted }) }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                if store.activityCategory != nil || store.activityCardID != nil || kind != nil || currency != nil {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                if let c = store.activityCategory { FilterChip(text: c.title) { store.activityCategory = nil } }
                                if let id = store.activityCardID, let card = store.card(id) { FilterChip(text: card.nickname) { store.activityCardID = nil } }
                                if let k = kind { FilterChip(text: k.title) { kind = nil } }
                                if let c = currency { FilterChip(text: c.rawValue) { currency = nil } }
                            }
                        }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(grouped, id: \.0) { month, items in
                    Section(Day.monthTitle(month)) {
                        ForEach(items) { t in
                            NavigationLink(value: Route.transaction(t.id)) { TransactionRow(transaction: t) }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .searchable(text: $search, prompt: "Merchant or description")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Card", selection: $store.activityCardID) {
                            Text("All cards").tag(String?.none)
                            ForEach(store.cards) { Text($0.nickname).tag(Optional($0.id)) }
                        }
                        Picker("Kind", selection: $kind) {
                            Text("All kinds").tag(TransactionKind?.none)
                            ForEach(TransactionKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                        Picker("Currency", selection: $currency) {
                            Text("All currencies").tag(CurrencyCode?.none)
                            ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag(Optional($0)) }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .withRoutes()
        }
    }
}

struct FilterChip: View {
    let text: String
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: "xmark.circle.fill")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter \(text)")
    }
}

struct TransactionRow: View {
    @Environment(Store.self) private var store
    let transaction: Transaction

    var body: some View {
        let t = transaction
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12), in: Circle())
                .foregroundStyle(t.kind == .issuerCredit || t.kind == .offerCredit ? .green : .primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.merchant).lineLimit(1)
                HStack(spacing: 4) {
                    Text(Day.format(t.posted, .dateTime.month(.abbreviated).day()))
                    if let card = store.card(t.cardID) { Text("· \(card.nickname)") }
                    if t.pending { Text("· Pending").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(t.amount.formatted)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(t.amount.minor < 0 ? .green : .primary)
                if let link = store.benefits.evidence[t.id]?.first {
                    Image(systemName: link.status.symbol).font(.caption).foregroundStyle(link.status.color)
                        .accessibilityLabel(link.status.rawValue)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch transaction.kind {
        case .purchase: transaction.category.symbol
        case .refund: "arrow.uturn.backward"
        case .issuerCredit: "gift"
        case .offerCredit: "tag"
        case .fee: "doc.plaintext"
        case .payment: "arrow.down.left"
        }
    }
}

struct TransactionDetailView: View {
    @Environment(Store.self) private var store
    let transactionID: String

    var body: some View {
        if let t = store.transaction(transactionID) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.merchant).font(.title3.weight(.semibold))
                        Text(t.amount.formatted).font(.largeTitle.weight(.semibold).monospacedDigit())
                            .foregroundStyle(t.amount.minor < 0 ? .green : .primary)
                        Text(t.kind.title).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section("Details") {
                    if let card = store.card(t.cardID) { LabeledContent("Card", value: "\(card.nickname) •••• \(card.mask ?? "")") }
                    LabeledContent("Posted", value: Day.format(t.posted))
                    if let a = t.authorized { LabeledContent("Authorized", value: Day.format(a)) }
                    LabeledContent("Status", value: t.pending ? "Pending" : "Posted")
                    LabeledContent("Original description", value: t.originalDescription)
                    LabeledContent("Source", value: t.provenance.rawValue)
                    if t.kind == .purchase || t.kind == .refund {
                        Picker("Category", selection: Binding(get: { t.category }, set: { store.setCategory($0, for: t.id) })) {
                            ForEach(RewardCategory.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                let links = store.benefits.evidence[t.id] ?? []
                if !links.isEmpty || store.decisions[t.id] != nil {
                    Section("Benefit matches") {
                        ForEach(links, id: \.self) { link in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    StatusBadge(text: link.status.rawValue, color: link.status.color, symbol: link.status.symbol)
                                    Spacer()
                                    if let p = store.benefits.period(link.periodID) {
                                        Text(p.rule.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(link.note).font(.callout)
                                if let p = store.benefits.period(link.periodID) {
                                    NavigationLink("View \(Day.monthTitle(p.start)) period", value: Route.period(p.id)).font(.callout)
                                }
                                if link.status == .needsReview {
                                    NavigationLink("Review this credit", value: Route.review(t.id)).font(.callout)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        if store.decisions[t.id] != nil {
                            Button("Undo my decision") { store.undoDecision(t.id) }
                        }
                    }
                }
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
