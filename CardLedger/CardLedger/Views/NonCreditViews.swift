import SwiftUI

// MARK: - In-app credits (Uber Cash, DoorDash promos, Lyft)

/// Replaces "Confirmed credits / Purchase evidence" for credits spent inside a merchant's app.
struct AppCreditUsageSection: View {
    @Environment(Store.self) private var store
    let period: BenefitPeriod
    @State private var logging = false

    var body: some View {
        let logs = store.usage(for: period.id)
        Section {
            if logs.isEmpty {
                Text("Nothing logged yet. Use doesn't appear on your statement, so mark it here when you spend it in the app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(logs) { log in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Day.format(log.usedOn))
                        if !log.note.isEmpty { Text(log.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(log.amount.formatted).monospacedDigit().foregroundStyle(.green)
                }
                .swipeActions { Button("Delete", role: .destructive) { store.deleteUsage(log.id) } }
            }
            if period.remaining.minor > 0 {
                Button {
                    store.logUsage(periodID: period.id, amount: period.remaining, usedOn: store.today, note: "Used in full")
                } label: {
                    Label("Used all \(period.remaining.short)", systemImage: "checkmark.circle")
                }
                Button { logging = true } label: { Label("Log partial use…", systemImage: "plus.circle") }
            }
        } header: {
            Text("Used in the app")
        } footer: {
            Text("\(period.rule.redemption.label): applied in the merchant's app, not as a statement credit. Unused value usually expires at the end of the period.")
        }
        .sheet(isPresented: $logging) { LogUsageSheet(period: period) }
    }
}

struct LogUsageSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let period: BenefitPeriod
    @State private var amountText = ""
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount (\(period.cap.currency.rawValue))", text: $amountText).keyboardType(.decimalPad)
                    DatePicker("Used on", selection: $date, in: period.start...Day.add(-1, to: period.end).addingTimeInterval(86_399),
                               displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                } footer: {
                    Text("\(period.remaining.formatted) left this period.")
                }
            }
            .navigationTitle(period.rule.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value = Double(amountText.replacingOccurrences(of: ",", with: "")), value > 0 else { return }
                        let amount = Money(min(Int((value * 100).rounded()), period.remaining.minor), period.cap.currency)
                        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
                        store.logUsage(periodID: period.id, amount: amount, usedOn: Day.make(c.year!, c.month!, c.day!), note: note)
                        dismiss()
                    }
                    .disabled(Double(amountText.replacingOccurrences(of: ",", with: "")) == nil)
                }
            }
            .onAppear { amountText = period.remaining.decimal.formatted(.number.precision(.fractionLength(2)).grouping(.never)) }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Free nights and memberships on card detail

struct CertificatesAndMembershipsSection: View {
    @Environment(Store.self) private var store
    let card: Card
    @State private var editing: AwardCertificate?

    var body: some View {
        let statuses = store.certificateStatuses(for: card)
        let memberships = Catalog.product(card.productID).benefits.filter { $0.redemption == .membership }
        if !statuses.isEmpty {
            Section {
                ForEach(statuses) { status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(status.rule.name, systemImage: "bed.double").font(.callout.weight(.semibold))
                            Spacer()
                        }
                        Text(status.spec.capText).font(.caption).foregroundStyle(.secondary)
                        if let spend = status.spend, let threshold = status.threshold {
                            ProgressView(value: min(1, Double(spend.minor) / Double(max(1, threshold.minor))))
                            Text("\(spend.short) of \(threshold.short) this year").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(status.expectation).font(.caption)
                            .foregroundStyle(status.pending ? (status.expectedBy.map { $0 < store.today } ?? false ? .red : .orange) : .secondary)
                        if let basis = status.basis {
                            Text("Estimated from: \(basis)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    ForEach(status.certificates) { cert in
                        Button { editing = cert } label: { CertificateRow(certificate: cert, showCard: nil) }.tint(.primary)
                    }
                    Button {
                        // Prefill with the estimate when an award is due; the owner corrects it from the loyalty account.
                        let issued = status.pending ? min(store.today, status.expectedBy ?? store.today) : store.today
                        editing = AwardCertificate(id: UUID().uuidString, cardID: card.id, ruleID: status.rule.id,
                                                   issuedOn: issued, expiresOn: Day.addMonths(status.spec.validMonths, to: issued),
                                                   redeemedOn: nil, note: "")
                    } label: {
                        Label("Record an award from your account", systemImage: "plus.circle").font(.callout)
                    }
                }
            } header: {
                Text("Free night awards")
            } footer: {
                Text("Awards go to your loyalty account, not your statement. Record the issue and expiry dates shown there to get reminders.")
            }
            .sheet(item: $editing) { CertificateEditor(certificate: $0) }
        }
        if !memberships.isEmpty {
            Section("Memberships") {
                ForEach(memberships) { rule in
                    let activated = store.membershipActivated(card, rule)
                    Toggle(isOn: Binding(get: { activated != nil },
                                         set: { store.setMembership(card, rule, activatedOn: $0 ? store.today : nil) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                            Text(activated.map { "Activated \(Day.format($0)) · worth about \(rule.cap.short)/yr" }
                                 ?? "Not activated · worth about \(rule.cap.short)/yr")
                                .font(.caption).foregroundStyle(.secondary)
                            if !rule.notes.isEmpty { Text(rule.notes).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }
}

struct CertificateRow: View {
    @Environment(Store.self) private var store
    let certificate: AwardCertificate
    let showCard: Card?

    var body: some View {
        let state = certificate.state(today: store.today)
        let days = Day.days(from: store.today, to: certificate.lastDay)
        HStack {
            if let showCard { CardThumbnail(product: Catalog.product(showCard.productID), height: 22) }
            VStack(alignment: .leading, spacing: 2) {
                Text(rule?.name ?? "Free night").font(.callout)
                Text(state == .redeemed ? "Redeemed \(certificate.redeemedOn.map { Day.format($0) } ?? "")"
                     : "Expires \(Day.format(certificate.lastDay))")
                    .font(.caption).foregroundStyle(.secondary)
                if !certificate.note.isEmpty { Text(certificate.note).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if state == .available {
                DaysLeftText(days: max(0, days))
            } else {
                StatusBadge(text: state.rawValue, color: state == .redeemed ? .green : .red)
            }
        }
    }

    private var rule: BenefitRule? {
        store.card(certificate.cardID).flatMap { c in Catalog.product(c.productID).benefits.first { $0.id == certificate.ruleID } }
    }
}

struct CertificateEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var certificate: AwardCertificate
    @State private var redeemed = false
    @State private var redeemedOn = Date()

    private var isNew: Bool { !store.certificates.contains { $0.id == certificate.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Issued", selection: $certificate.issuedOn, displayedComponents: .date)
                    DatePicker("Expires", selection: $certificate.expiresOn, displayedComponents: .date)
                } footer: {
                    Text("Use the dates shown in your loyalty account. The expiry date is the first day it can no longer be used.")
                }
                Section {
                    Toggle("Redeemed", isOn: $redeemed)
                    if redeemed { DatePicker("Redeemed on", selection: $redeemedOn, displayedComponents: .date) }
                    TextField("Note (hotel, stay dates)", text: $certificate.note)
                }
                if !isNew {
                    Section { Button("Delete award", role: .destructive) { store.deleteCertificate(certificate.id); dismiss() } }
                }
            }
            .navigationTitle(isNew ? "Record award" : "Free night award")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var c = certificate
                        c.issuedOn = localDay(c.issuedOn)
                        c.expiresOn = localDay(c.expiresOn)
                        c.redeemedOn = redeemed ? localDay(redeemedOn) : nil
                        store.saveCertificate(c)
                        dismiss()
                    }
                }
            }
            .onAppear {
                redeemed = certificate.redeemedOn != nil
                redeemedOn = certificate.redeemedOn ?? Date()
            }
        }
    }

    private func localDay(_ d: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return Day.make(c.year!, c.month!, c.day!)
    }
}
