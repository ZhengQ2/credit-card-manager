import SwiftUI

/// RewardRadar-style "which card should I use?", driven by the real ledger for remaining caps.
struct BestCardView: View {
    @Environment(Store.self) private var store
    @State private var currency: CurrencyCode = .cad
    @State private var expanded: RewardCategory?

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
                ForEach(RewardCategory.allCases) { category in
                    let ranking = engine.rank(category: category, currency: currency, amount: Money(10_000, currency),
                                              usage: capUsage, today: store.today)
                    let pinned = store.pinnedCard[category]
                    if !ranking.isEmpty {
                        Section {
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
            .navigationTitle("Best Card")
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
    @State private var showPairing = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    if let p = store.pairing {
                        LabeledContent("Service", value: p.baseURL.host() ?? p.baseURL.absoluteString)
                        LabeledContent("Environment", value: p.environment)
                        Button("Unpair this iPhone", role: .destructive) { store.unpair() }
                    } else {
                        Button("Pair with service…") { showPairing = true }
                    }
                    LabeledContent("Data on this iPhone", value: store.mode == .live ? "Your ledger (encrypted)" : "Sample data")
                } header: { Text("Service connection") } footer: {
                    Text("Bank access goes through your own service. Plaid is the only external financial data processor.")
                }

                Section {
                    Toggle("Require Face ID or passcode", isOn: Binding(get: { store.requireDeviceAuth }, set: { store.setRequireDeviceAuth($0) }))
                    LabeledContent("Storage", value: store.storageError == nil ? "SQLCipher, AES-256" : "Unavailable")
                } header: { Text("Security") }

                Section("Reminders") {
                    ForEach([14, 7, 2], id: \.self) { d in
                        Toggle("\(d) days before a deadline", isOn: Binding(
                            get: { store.reminderOffsets.contains(d) },
                            set: { on in if on { store.reminderOffsets.insert(d) } else { store.reminderOffsets.remove(d) } }))
                    }
                    Text("Delivered at 9 AM with a generic lock-screen message.").font(.caption).foregroundStyle(.secondary)
                }

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

                Section("Privacy") {
                    LabeledContent("iCloud sync", value: "Off")
                    LabeledContent("Analytics", value: "None")
                    Button("Export encrypted archive…") {}
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPairing) { PairingView() }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
