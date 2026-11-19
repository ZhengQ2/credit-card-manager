import SwiftUI

struct BenefitDetailView: View {
    @Environment(Store.self) private var store
    let periodID: String

    var body: some View {
        if let p = store.benefits.period(periodID) {
            content(p)
        } else {
            ContentUnavailableView("Benefit period not found", systemImage: "questionmark")
        }
    }

    @ViewBuilder
    private func content(_ p: BenefitPeriod) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CardChip(card: p.card)
                        VStack(alignment: .leading) {
                            Text(p.card.nickname).font(.subheadline.weight(.semibold))
                            Text(p.windowLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(text: p.state.rawValue, color: p.state.color)
                    }
                    UsageBar(period: p)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow { Text("Cap").foregroundStyle(.secondary); Text("\(p.cap.formatted) \(p.rule.period.title)") }
                        GridRow { Text("Confirmed").foregroundStyle(.secondary); Text(p.confirmed.formatted).foregroundStyle(.green) }
                        if p.awaiting.minor > 0 {
                            GridRow { Text("Awaiting").foregroundStyle(.secondary); Text(p.awaiting.formatted).foregroundStyle(.orange) }
                        }
                        GridRow { Text("Remaining").foregroundStyle(.secondary); Text(p.remaining.formatted).fontWeight(.semibold) }
                        if p.isCurrent(today: store.today) {
                            GridRow { Text("Ends").foregroundStyle(.secondary); Text("\(Day.format(p.lastDay)) (final eligible day)") }
                        }
                    }
                    .font(.callout.monospacedDigit())
                }
                .padding(.vertical, 4)
            }

            if p.rule.redemption == .appCredit {
                AppCreditUsageSection(period: p)
            } else {
                Section("Confirmed credits") {
                    if p.allocations.isEmpty {
                        Text("No issuer credit matched yet.").foregroundStyle(.secondary)
                    }
                    ForEach(p.allocations) { a in
                        NavigationLink(value: Route.transaction(a.creditID)) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(store.transaction(a.creditID).map { Day.format($0.posted) } ?? "")
                                    Spacer()
                                    Text(a.amount.formatted).monospacedDigit().foregroundStyle(.green)
                                }
                                Text(a.reason).font(.caption).foregroundStyle(.secondary)
                                Text(a.origin.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Purchase evidence") {
                    if p.eligiblePurchases.isEmpty && p.pendingPurchases.isEmpty {
                        Text("No eligible purchases in this window.").foregroundStyle(.secondary)
                    }
                    ForEach(p.eligiblePurchases + p.pendingPurchases + p.refunds) { t in
                        NavigationLink(value: Route.transaction(t.id)) {
                            EvidenceRow(transaction: t, link: store.benefits.evidence[t.id]?.first { $0.periodID == p.id })
                        }
                    }
                }
            }

            let previous = store.benefits.periods
                .filter { $0.rule.id == p.rule.id && $0.card.id == p.card.id && $0.id != p.id }
                .sorted { $0.start > $1.start }
            if !previous.isEmpty {
                Section("Other periods") {
                    ForEach(previous) { q in
                        NavigationLink(value: Route.period(q.id)) {
                            HStack {
                                Text(q.windowLabel)
                                Spacer()
                                Text("\(q.confirmed.short) / \(q.cap.short)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Rule version", value: "v\(p.rule.version)")
                LabeledContent("Redeemed as", value: p.rule.redemption.label)
                if p.rule.redemption == .statementCredit {
                    LabeledContent("Credit descriptor", value: p.rule.creditDescriptor)
                    LabeledContent("Expected credit lag", value: "Up to \(p.rule.creditLagDays) days")
                }
                if p.rule.requiresEnrollment { LabeledContent("Enrollment", value: "Required") }
                Text(p.rule.notes).font(.callout).foregroundStyle(.secondary)
                Link(destination: p.rule.sourceURL) { Label("Issuer terms", systemImage: "safari") }
            } header: { Text("Rule") }
        }
        .navigationTitle(p.rule.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EvidenceRow: View {
    let transaction: Transaction
    let link: EvidenceLink?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant)
                Text("\(Day.format(transaction.posted)) · \(transaction.kind.title)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.amount.formatted).monospacedDigit()
                if let link { StatusBadge(text: link.status.rawValue, color: link.status.color) }
            }
        }
    }
}

struct ReviewListView: View {
    @Environment(Store.self) private var store

    var body: some View {
        List {
            if store.openReviews.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal", description: Text("All credits are matched or kept unmatched."))
            }
            ForEach(store.openReviews) { item in
                NavigationLink(value: Route.review(item.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.credit.originalDescription).font(.callout.weight(.semibold))
                            Spacer()
                            Text(item.credit.amount.formatted).monospacedDigit()
                        }
                        Text("\(item.card.nickname) · \(Day.format(item.credit.posted))").font(.caption).foregroundStyle(.secondary)
                        Text(item.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Review credits")
    }
}

struct CreditReviewView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let creditID: String
    @State private var selection: String?

    var body: some View {
        if let item = store.openReviews.first(where: { $0.id == creditID }) {
            List {
                Section("What is ambiguous") {
                    LabeledContent("Credit", value: item.credit.amount.formatted)
                    LabeledContent("Posted", value: Day.format(item.credit.posted))
                    LabeledContent("Description", value: item.credit.originalDescription)
                    Text(item.reason).foregroundStyle(.secondary)
                }

                Section {
                    if item.candidatePeriodIDs.isEmpty {
                        Text("No eligible period has an unreimbursed purchase. You can keep this credit unmatched.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(item.candidatePeriodIDs, id: \.self) { id in
                        if let p = store.benefits.period(id) {
                            Button { selection = id } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: selection == id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selection == id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(p.rule.name).foregroundStyle(.primary)
                                        Text("\(p.windowLabel) · \(p.remaining.short) left").font(.caption).foregroundStyle(.secondary)
                                        ForEach(p.eligiblePurchases.filter { store.benefits.evidence[$0.id]?.contains { $0.status == .awaitingCredit || $0.status == .notCredited } ?? false }) { t in
                                            Text("• \(t.merchant) \(t.amount.short) on \(Day.format(t.posted, .dateTime.month(.abbreviated).day()))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .accessibilityAddTraits(selection == id ? .isSelected : [])
                        }
                    }
                } header: {
                    Text("Eligible benefit periods")
                } footer: {
                    Text("Select a period to confirm. Your decision is kept across syncs.")
                }

                Section {
                    Button("Confirm match") {
                        if let selection { store.decide(item.id, .assign(periodID: selection)); dismiss() }
                    }
                    .disabled(selection == nil)
                    Button("Keep unmatched", role: .destructive) {
                        store.decide(item.id, .keepUnmatched); dismiss()
                    }
                } footer: {
                    Text("Keeping it unmatched dismisses the suggestion. The credit stays visible in Activity.")
                }
            }
            .navigationTitle("Credit review")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Review resolved", systemImage: "checkmark.seal")
        }
    }
}
