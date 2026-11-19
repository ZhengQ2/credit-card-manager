import SwiftUI

enum Route: Hashable {
    case period(String)
    case transaction(String)
    case card(String)
    case reviews
    case review(String)
    case compare
}

struct RouteDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case .period(let id): BenefitDetailView(periodID: id)
            case .transaction(let id): TransactionDetailView(transactionID: id)
            case .card(let id): CardDetailView(cardID: id)
            case .reviews: ReviewListView()
            case .review(let id): CreditReviewView(creditID: id)
            case .compare: CompareView()
            }
        }
    }
}

extension View {
    func withRoutes() -> some View { modifier(RouteDestinations()) }
}

struct OverviewView: View {
    @Environment(Store.self) private var store
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                syncSection

                let bills = store.upcomingCardBills
                if !bills.isEmpty {
                    Section("Upcoming card payments") {
                        ForEach(bills) { bill in
                            if let card = store.card(bill.cardID) {
                                NavigationLink(value: Route.card(card.id)) {
                                    LabeledContent(card.nickname, value: "Due \(Day.format(bill.dueDate))")
                                }
                            }
                        }
                    }
                }

                if let next = store.activeDeadlines.first {
                    Section("Next expiring") {
                        NavigationLink(value: Route.period(next.id)) { NextDeadlineCard(period: next) }
                    }
                }

                if !store.openReviews.isEmpty {
                    Section {
                        NavigationLink(value: Route.reviews) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text("\(store.openReviews.count) credit\(store.openReviews.count == 1 ? "" : "s") to review")
                                    Text("Ambiguous matches are not counted until you confirm them.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "questionmark.circle.fill").foregroundStyle(.purple)
                            }
                        }
                    }
                }

                if store.activeDeadlines.count > 1 {
                    Section("Upcoming deadlines") {
                        ForEach(store.activeDeadlines.dropFirst()) { p in
                            NavigationLink(value: Route.period(p.id)) { DeadlineRow(period: p) }
                        }
                    }
                }

                if !store.availableCertificates.isEmpty || !store.expectedAwards.isEmpty {
                    Section("Free night awards") {
                        ForEach(store.availableCertificates) { cert in
                            NavigationLink(value: Route.card(cert.cardID)) {
                                CertificateRow(certificate: cert, showCard: store.card(cert.cardID))
                            }
                        }
                        ForEach(store.expectedAwards) { st in
                            NavigationLink(value: Route.card(st.card.id)) {
                                HStack {
                                    CardThumbnail(product: Catalog.product(st.card.productID), height: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(st.rule.name) · \(st.card.nickname)").font(.callout)
                                        Text(st.expectation).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatusBadge(text: st.pending ? ((st.expectedBy ?? .distantFuture) < store.today ? "Check account" : "Expected") : "Upcoming",
                                                color: st.pending ? .orange : .secondary)
                                }
                            }
                        }
                    }
                }

                if !store.activeOffers.isEmpty {
                    Section("Welcome offers") {
                        ForEach(store.activeOffers, id: \.offer.id) { p in
                            NavigationLink(value: Route.card(p.offer.cardID)) {
                                WelcomeOfferRow(progress: p, showCard: store.card(p.offer.cardID))
                            }
                        }
                    }
                }

                let unconfirmed = store.cards.filter { $0.openDateStatus == .estimated && $0.connectionID != nil }
                if !unconfirmed.isEmpty {
                    Section {
                        ForEach(unconfirmed) { card in
                            NavigationLink(value: Route.card(card.id)) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Confirm when you opened \(card.nickname)")
                                        Text("History starts \(Day.format(card.historyStart)). Affects 5/24 and welcome offers.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange) }
                            }
                        }
                    }
                }

                if !store.upcomingFees.isEmpty {
                    Section {
                        ForEach(store.upcomingFees, id: \.0.id) { card, renewal in
                            NavigationLink(value: Route.card(card.id)) {
                                HStack {
                                    CardChip(card: card, size: 28)
                                    VStack(alignment: .leading) {
                                        Text("\(card.nickname) annual fee")
                                        Text(renewal.precision == .month
                                             ? "Expected \(Day.format(renewal.date, .dateTime.month(.wide).year())) · \(renewal.source.rawValue)"
                                             : "Due \(Day.format(renewal.date)) · \(renewal.source.rawValue)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Catalog.product(card.productID).annualFee.short).font(.callout.monospacedDigit())
                                }
                            }
                        }
                    } header: {
                        Text("Annual fees ahead")
                    } footer: {
                        Text("Effective fee after credits used is on each card.")
                    }
                }
            }
            .navigationTitle("Overview")
            .refreshable { await store.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await store.sync() } } label: { Label("Sync now", systemImage: "arrow.clockwise") }
                        Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .withRoutes()
        }
    }

    private var syncSection: some View {
        Section {
            HStack {
                if store.isSyncing {
                    ProgressView().padding(.trailing, 4)
                    Text("Syncing…")
                } else {
                    Image(systemName: "checkmark.icloud.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(store.lastSync.map { "Synced \($0.relativeAge)" } ?? "Not synced yet")
                }
                Spacer()
                if store.mode == .sample { Text("Sample data").font(.caption).foregroundStyle(.secondary) }
            }
            if let err = store.storageError {
                Label(err, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.red)
            }
            if let msg = store.syncMessage {
                Label(msg, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if store.unknownCurrencyCount > 0 {
                Label("\(store.unknownCurrencyCount) transaction\(store.unknownCurrencyCount == 1 ? "" : "s") in your ledger have an unsupported or unofficial currency and are excluded from totals.",
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.mode == .sample {
                Button { store.selectedTab = .cards } label: {
                    Label("Showing sample data. Connect a bank in Cards to see your own.", systemImage: "info.circle").font(.callout)
                }
            }
            ForEach(store.cards.filter { $0.connection.needsReauth }) { card in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("\(card.nickname): bank authorization required")
                        if let s = card.lastSync {
                            Text("Showing data from \(s.relativeAge)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Reconnect") { store.reconnect(card.id) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

struct NextDeadlineCard: View {
    @Environment(Store.self) private var store
    let period: BenefitPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                CardChip(card: period.card)
                VStack(alignment: .leading, spacing: 2) {
                    Text(period.rule.name).font(.headline)
                    Text(period.card.nickname).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                DaysLeftText(days: period.daysLeft(today: store.today))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(period.remaining.formatted).font(.title.weight(.semibold).monospacedDigit())
                Text("left of \(period.cap.short)").foregroundStyle(.secondary)
            }
            UsageBar(period: period)
            Text("Use by \(Day.format(period.lastDay))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct DeadlineRow: View {
    @Environment(Store.self) private var store
    let period: BenefitPeriod

    var body: some View {
        HStack(spacing: 12) {
            CardChip(card: period.card, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(period.rule.name)
                HStack(spacing: 6) {
                    Text(period.rule.redemption == .appCredit ? "\(period.card.nickname) · in app" : period.card.nickname)
                    Text("·")
                    Text("by \(Day.format(period.lastDay, .dateTime.month(.abbreviated).day()))")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(period.remaining.short).font(.callout.weight(.semibold).monospacedDigit())
                DaysLeftText(days: period.daysLeft(today: store.today))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
