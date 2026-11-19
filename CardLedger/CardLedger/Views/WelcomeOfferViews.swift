import SwiftUI

/// "Opened" rows on card detail: asks whether the covered-history date is the real open date.
struct OpenDateSection: View {
    @Environment(Store.self) private var store
    let card: Card
    @State private var pickingDate = false
    @State private var date = Day.toLocal(Day.today)
    @State private var offerSheet: WelcomeOffer?

    var body: some View {
        Group {
            switch card.openDateStatus {
            case .estimated:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Did you open this card on \(Day.format(card.openedOn))?")
                        .font(.callout.weight(.semibold))
                    Text("That's where your transaction history starts. Plaid doesn't share the real open date.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Yes") {
                            store.confirmOpenDate(card.id, date: card.openedOn, status: .confirmed)
                            offerSheet = newOffer(start: card.openedOn)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("No, it's older") { store.confirmOpenDate(card.id, date: nil, status: .older) }
                            .buttonStyle(.bordered)
                        Button("Set date") { date = Day.toLocal(card.openedOn); pickingDate = true }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            case .older:
                LabeledContent("Opened") {
                    VStack(alignment: .trailing) {
                        Text("Before \(Day.format(card.historyStart))")
                        Text("Not counted in 5/24").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Set the open date") { date = Day.toLocal(card.historyStart); pickingDate = true }
            case .confirmed:
                LabeledContent("Opened", value: Day.format(card.openedOn))
                Button("Change open date") { date = Day.toLocal(card.openedOn); pickingDate = true }.font(.callout)
            }
        }
        .sheet(isPresented: $pickingDate) {
            NavigationStack {
                Form {
                    DatePicker("Opened", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                .navigationTitle("Open date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingDate = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let day = Day.fromLocal(date)
                            store.confirmOpenDate(card.id, date: day, status: .confirmed)
                            pickingDate = false
                            // A newly opened card usually has a welcome offer worth tracking.
                            if Day.days(from: day, to: store.today) < 400, store.offers(for: card.id).isEmpty {
                                Task { try? await Task.sleep(for: .milliseconds(500)); offerSheet = newOffer(start: day) }
                            }
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $offerSheet) { WelcomeOfferEditor(offer: $0, isNew: true) }
    }

    private func newOffer(start: Date) -> WelcomeOffer {
        let currency = Catalog.product(card.productID).market
        return WelcomeOffer(id: UUID().uuidString, cardID: card.id, kind: .spendBonus, currency: currency, start: start, months: 3,
                            minSpend: Money(400_000, currency), points: 60_000, cash: nil, extraMultiplier: nil,
                            categories: [], spendCap: nil, notes: "", markedEarned: false)
    }
}

/// Welcome-offer section on card detail.
struct WelcomeOfferSection: View {
    @Environment(Store.self) private var store
    let card: Card
    @State private var editing: WelcomeOffer?
    @State private var isNew = false

    var body: some View {
        let offers = store.offers(for: card.id)
        if card.openDateStatus == .confirmed || !offers.isEmpty {
            Section {
                ForEach(offers) { offer in
                    Button { isNew = false; editing = offer } label: { WelcomeOfferRow(progress: store.progress(offer)) }
                        .tint(.primary)
                }
                Button {
                    isNew = true
                    let currency = Catalog.product(card.productID).market
                    editing = WelcomeOffer(id: UUID().uuidString, cardID: card.id, kind: .spendBonus, currency: currency, start: card.openedOn,
                                           months: 3, minSpend: Money(400_000, currency), points: 60_000, cash: nil,
                                           extraMultiplier: nil, categories: [], spendCap: nil, notes: "", markedEarned: false)
                } label: {
                    Label(offers.isEmpty ? "Add welcome offer" : "Add another offer", systemImage: "plus.circle")
                }
            } header: {
                Text("Welcome offer")
            } footer: {
                Text("Progress counts posted purchases minus refunds on this card inside the offer window.")
            }
            .sheet(item: $editing) { WelcomeOfferEditor(offer: $0, isNew: isNew) }
        }
    }
}

struct WelcomeOfferRow: View {
    let progress: WelcomeOfferProgress
    var showCard: Card? = nil

    var body: some View {
        let o = progress.offer
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let showCard { CardThumbnail(product: Catalog.product(showCard.productID), height: 22) }
                Label(o.kind.title, systemImage: o.kind.symbol).font(.callout.weight(.semibold))
                Spacer()
                StatusBadge(text: progress.state.rawValue, color: color)
            }
            Text(progress.reward).font(.subheadline)
            if o.kind.needsSpend, let target = o.minSpend {
                ProgressView(value: progress.fraction).tint(color)
                HStack {
                    Text("\(progress.spend.short) of \(target.short)")
                    Spacer()
                    if let left = progress.remaining, !left.isZero, progress.state == .inProgress {
                        Text("\(left.short) to go · \(progress.daysLeft)d left")
                    }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if o.kind == .bonusEarn {
                ProgressView(value: progress.fraction).tint(color)
                Text("≈ \(Int((progress.extraPoints ?? 0).rounded()).formatted()) extra points so far · \(progress.daysLeft)d left")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(Day.format(o.start)) – \(Day.format(o.lastDay))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch progress.state {
        case .met, .earned: .green
        case .missed: .red
        case .ended: .secondary
        case .inProgress: progress.daysLeft <= 14 ? .orange : .blue
        case .active: .blue
        }
    }
}

struct WelcomeOfferEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var offer: WelcomeOffer
    let isNew: Bool
    @State private var startDate = Day.toLocal(Day.today)
    @State private var spendText = ""
    @State private var pointsText = ""
    @State private var cashText = ""
    @State private var multText = ""
    @State private var capText = ""

    private var currency: CurrencyCode {
        store.card(offer.cardID).map { Catalog.product($0.productID).market } ?? offer.currency
    }

    private func parsePositive(_ s: String) -> Double? {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard let v = Double(cleaned), v.isFinite, v > 0 else { return nil }
        return v
    }

    private var canSave: Bool {
        switch offer.kind {
        case .spendBonus:
            return parsePositive(spendText) != nil && parsePositive(pointsText) != nil
        case .statementCredit:
            return parsePositive(spendText) != nil && parsePositive(cashText) != nil
        case .bonusEarn:
            let capOK = capText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsePositive(capText) != nil
            return parsePositive(multText) != nil && capOK
        case .feeWaiver:
            return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $offer.kind) {
                        ForEach(WelcomeOffer.Kind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    Stepper("Window: \(offer.months) month\(offer.months == 1 ? "" : "s")", value: $offer.months, in: 1...24)
                }

                switch offer.kind {
                case .spendBonus, .statementCredit:
                    Section("Requirement and reward") {
                        amountField("Minimum spend (\(currency.rawValue))", text: $spendText)
                        if offer.kind == .spendBonus {
                            amountField("Bonus points", text: $pointsText)
                        } else {
                            amountField("Credit (\(currency.rawValue))", text: $cashText)
                        }
                    }
                case .bonusEarn:
                    Section("Bonus earn") {
                        amountField("Extra multiplier (e.g. 4 for +4×)", text: $multText)
                        amountField("Spend cap (\(currency.rawValue), optional)", text: $capText)
                        ForEach(RewardCategory.allCases) { c in
                            Toggle(c.title, isOn: Binding(
                                get: { offer.categories.contains(c) },
                                set: { if $0 { offer.categories.insert(c) } else { offer.categories.remove(c) } }))
                        }
                    }
                case .feeWaiver:
                    Section {
                        let startDay = Day.fromLocal(startDate)
                        Text("No annual fee in the first cardmember year. Effective fee shows \(Money.zero(currency).short) until \(Day.format(Day.add(-1, to: Day.addMonths(max(offer.months, 12), to: startDay)))).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Notes (offer terms, link)", text: $offer.notes, axis: .vertical)
                    if offer.kind.needsSpend {
                        Toggle("Bonus posted", isOn: $offer.markedEarned)
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete offer", role: .destructive) { store.deleteOffer(offer.id); dismiss() }
                    }
                }
            }
            .navigationTitle(isNew ? "Welcome offer" : offer.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(isNew ? "Skip" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .onAppear(perform: load)
        }
    }

    private func amountField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).keyboardType(.decimalPad)
    }

    private func load() {
        let fmt: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) }
        startDate = Day.toLocal(offer.start)
        spendText = offer.minSpend.map { fmt($0.decimal) } ?? ""
        pointsText = offer.points.map(fmt) ?? ""
        cashText = offer.cash.map { fmt($0.decimal) } ?? ""
        multText = offer.extraMultiplier.map(fmt) ?? ""
        capText = offer.spendCap.map { fmt($0.decimal) } ?? ""
    }

    private func save() {
        var o = offer
        o.currency = currency
        o.start = Day.fromLocal(startDate)
        o.minSpend = o.kind.needsSpend ? parsePositive(spendText).map { Money.dollars($0, currency) } : nil
        o.points = o.kind == .spendBonus ? parsePositive(pointsText) : nil
        o.cash = o.kind == .statementCredit ? parsePositive(cashText).map { Money.dollars($0, currency) } : nil
        o.extraMultiplier = o.kind == .bonusEarn ? parsePositive(multText) : nil
        o.spendCap = o.kind == .bonusEarn ? parsePositive(capText).map { Money.dollars($0, currency) } : nil
        if o.kind != .bonusEarn { o.categories = [] }
        if o.kind == .feeWaiver { o.months = max(o.months, 12) }
        store.saveOffer(o)
        dismiss()
    }
}
