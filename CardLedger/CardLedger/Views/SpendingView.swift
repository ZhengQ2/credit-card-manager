import SwiftUI
import Charts

struct SpendingView: View {
    @Environment(Store.self) private var store
    @State private var month: Date = Day.startOfMonth(Day.today)
    @State private var currency: CurrencyCode = .usd
    @State private var showChart = true

    private var months: [Date] {
        let current = Day.startOfMonth(store.today)
        let earliest = store.effectiveTransactions.map(\.posted).min().map(Day.startOfMonth) ?? current
        var list: [Date] = []
        var cursor = current
        while list.count < 24 && (list.count < 4 || cursor >= earliest) {
            list.append(cursor)
            cursor = Day.addMonths(-1, to: cursor)
        }
        return list
    }

    private var inMonth: [Transaction] {
        let end = Day.addMonths(1, to: month)
        return store.effectiveTransactions.filter { $0.posted >= month && $0.posted < end && $0.amount.currency == currency && !$0.pending }
    }

    private func total(_ kinds: Set<TransactionKind>, _ txs: [Transaction]? = nil) -> Money {
        (txs ?? inMonth).filter { kinds.contains($0.kind) }.reduce(.zero(currency)) { $0 + $1.amount }
    }

    private var byCategory: [(RewardCategory, Money)] {
        Dictionary(grouping: inMonth.filter { $0.kind == .purchase || $0.kind == .refund }, by: \.category)
            .map { ($0.key, $0.value.reduce(Money.zero(currency)) { $0 + $1.amount }) }
            .filter { $0.1.minor != 0 }
            .sorted { $0.1 > $1.1 }
    }

    private var byCard: [(Card, Money)] {
        store.cards.compactMap { card in
            let txs = inMonth.filter { $0.cardID == card.id }
            guard !txs.isEmpty else { return nil }
            return (card, total([.purchase, .refund], txs))
        }
        .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Month", selection: $month) {
                        ForEach(months, id: \.self) { Text(Day.monthTitle($0)).tag($0) }
                    }
                    Picker("Currency", selection: $currency) {
                        ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Net spend").font(.subheadline).foregroundStyle(.secondary)
                        Text(total([.purchase, .refund]).formatted).font(.largeTitle.weight(.semibold).monospacedDigit())
                        Text("Posted purchases minus merchant refunds").font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Fees", value: total([.fee]).formatted)
                    LabeledContent("Net statement credits", value: total([.issuerCredit, .issuerCreditReversal]).formatted)
                    LabeledContent("Card-linked offers", value: total([.offerCredit]).formatted)
                    LabeledContent("Payments (excluded)", value: total([.payment]).formatted)
                } footer: {
                    Text("Currencies are never combined without a conversion basis you supply.")
                }

                if !byCategory.isEmpty {
                    let positiveCategories = byCategory.filter { $0.1.minor > 0 }
                    Section {
                        if showChart && !positiveCategories.isEmpty {
                            Chart(positiveCategories, id: \.0) { cat, amount in
                                BarMark(x: .value("Amount", amount.decimal), y: .value("Category", cat.title))
                                    .foregroundStyle(Color.accentColor.gradient)
                                    .annotation(position: .trailing) {
                                        Text(amount.short).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                            }
                            .chartXAxis(.hidden)
                            .frame(height: CGFloat(positiveCategories.count) * 34 + 10)
                            .accessibilityHidden(true)
                        }
                        ForEach(byCategory, id: \.0) { cat, amount in
                            Button {
                                store.activityCategory = cat
                                store.activityCardID = nil
                                store.selectedTab = .activity
                            } label: {
                                HStack {
                                    Label(cat.title, systemImage: cat.symbol)
                                    Spacer()
                                    Text(amount.formatted).monospacedDigit().foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                        }
                    } header: {
                        HStack {
                            Text("Top categories")
                            Spacer()
                            if !positiveCategories.isEmpty {
                                Button(showChart ? "Hide chart" : "Show chart") { showChart.toggle() }.font(.caption)
                            }
                        }
                    }

                    Section("By card") {
                        ForEach(byCard, id: \.0.id) { card, amount in
                            HStack {
                                CardChip(card: card, size: 24)
                                Text(card.nickname)
                                Spacer()
                                Text(amount.formatted).monospacedDigit()
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No \(currency.rawValue) spending", systemImage: "chart.bar", description: Text("Nothing posted in \(Day.monthTitle(month))."))
                }

                Section {
                    NavigationLink(value: Route.compare) {
                        Label("Compare cards", systemImage: "arrow.left.arrow.right")
                    }
                } footer: {
                    Text("Replays your purchases against the cards you already hold.")
                }

                Section("Coverage") {
                    ForEach(store.cards) { card in
                        LabeledContent(card.nickname, value: "from \(Day.format(card.historyStart))")
                    }
                }
            }
            .navigationTitle("Spending")
            .withRoutes()
        }
    }
}

struct CompareView: View {
    @Environment(Store.self) private var store
    @State private var currency: CurrencyCode = .usd
    @State private var airfareOnly = true
    @State private var range = 3

    private var result: RewardsEngine.ReplayResult {
        let start = Day.addMonths(-(range - 1), to: Day.startOfMonth(store.today))
        let all = store.effectiveTransactions
        let txs = all.filter { $0.posted >= start && (!airfareOnly || $0.category == .flights) }
        return store.rewards.replay(txs, allTransactions: all, currency: currency)
    }

    var body: some View {
        let r = result
        List {
            Section {
                Picker("Currency", selection: $currency) {
                    ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Direct airfare only", isOn: $airfareOnly)
                Stepper("Last \(range) month\(range == 1 ? "" : "s")", value: $range, in: 1...24)
            }

            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Actual").font(.caption).foregroundStyle(.secondary)
                        Text(r.actualTotal.money(currency).formatted).font(.title3.weight(.semibold).monospacedDigit())
                    }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Best held card").font(.caption).foregroundStyle(.secondary)
                        Text(r.alternativeTotal.money(currency).formatted).font(.title3.weight(.semibold).monospacedDigit())
                    }
                }
                LabeledContent("Change in value") {
                    Text((r.delta >= 0 ? "+" : "") + r.delta.money(currency).formatted)
                        .fontWeight(.semibold)
                        .foregroundStyle(r.delta > 0 ? .green : .secondary)
                }
            } footer: {
                Text("Estimated reward value minus modeled foreign-exchange costs, in \(currency.rawValue). Annual fees are not applied because no card is acquired or cancelled.")
            }

            Section("Purchases replayed (\(r.lines.count))") {
                if r.lines.isEmpty { Text("No matching purchases.").foregroundStyle(.secondary) }
                ForEach(r.lines) { line in
                    NavigationLink(value: Route.transaction(line.transaction.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(line.transaction.merchant).font(.callout.weight(.semibold))
                                Spacer()
                                Text(line.transaction.amount.formatted).font(.callout.monospacedDigit())
                            }
                            QuoteLine(label: "Used", quote: line.actual, currency: currency)
                            if line.alternative.card.id != line.actual.card.id {
                                QuoteLine(label: "Best", quote: line.alternative, currency: currency)
                            } else {
                                Text("Already on the best held card").font(.caption).foregroundStyle(.green)
                            }
                        }
                    }
                }
            }

            Section("Assumptions") {
                ForEach(Catalog.programs) { p in
                    LabeledContent(p.name, value: "\((store.assumptions.centsPerPoint[p.id] ?? 0).formatted())¢ \(p.currency.rawValue)")
                }
                LabeledContent("Exchange rate", value: "1 USD = \(store.assumptions.cadPerUSD.formatted()) CAD")
                Text("Bonus rates that depend on a booking channel the feed cannot see are counted at the base rate. Statement credits are not reallocated in this prototype. Edit values in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(r.notes.enumerated()), id: \.offset) { _, note in
                    Text("\(note.0.merchant): \(note.1)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Compare cards")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct QuoteLine: View {
    let label: String
    let quote: EarnQuote
    let currency: CurrencyCode

    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 34, alignment: .leading)
            CardChip(card: quote.card, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(quote.card.nickname) · \(Int(quote.points.rounded()).formatted()) pts")
                Text(quote.explanation).foregroundStyle(.secondary)
            }
            Spacer()
            Text(quote.netValueMinor.money(currency).short).monospacedDigit()
        }
        .font(.caption)
    }
}
