import SwiftUI

// MARK: - In-app credits (Uber Cash, DoorDash promos, Lyft)

struct BenefitUsageSection: View {
    @Environment(Store.self) private var store
    let period: BenefitPeriod
    @State private var logging = false
    @State private var saveFailed = false

    private var isStatementCredit: Bool { period.rule.redemption == .statementCredit }

    var body: some View {
        let logs = store.usage(for: period.id)
        Section {
            if logs.isEmpty && !isStatementCredit {
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
            if period.remaining.minor > 0 && (!isStatementCredit || period.canLogStatementCredit) {
                if !isStatementCredit {
                    Button {
                        saveFailed = !store.logUsage(periodID: period.id, amount: period.remaining,
                                                     usedOn: min(store.today, period.lastDay), note: "Used in full")
                    } label: {
                        Label("Used all \(period.remaining.short)", systemImage: "checkmark.circle")
                    }
                }
                Button { logging = true } label: {
                    Label(isStatementCredit ? "Mark statement credit used…" : "Log partial use…", systemImage: "plus.circle")
                }
            }
        } header: {
            Text(isStatementCredit ? "Manually recorded credits" : "Used in the app")
        } footer: {
            if isStatementCredit {
                Text("Recorded credits reduce the effective annual fee. Issuer credits matched later take precedence for this period.")
            } else {
                Text("\(period.rule.redemption.label): applied in the merchant's app, not as a statement credit. Unused value usually expires at the end of the period.")
            }
        }
        .sheet(isPresented: $logging) { LogUsageSheet(period: period) }
        .alert("Credit use could not be saved", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
    }
}

struct LogUsageSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let period: BenefitPeriod
    @State private var amountText = ""
    @State private var date = Day.toLocal(Day.today)
    @State private var note = ""
    @State private var saveFailed = false

    private var parsedAmount: Money? {
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        let text = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: decimalSeparator, with: ".")
        guard text.range(of: #"\A(?:[0-9]+(?:\.[0-9]{0,2})?|\.[0-9]{1,2})\z"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let minor = value * 100
        guard minor > 0, minor <= Decimal(period.remaining.minor) else { return nil }
        return Money(NSDecimalNumber(decimal: minor).intValue, period.cap.currency)
    }

    private var localRange: ClosedRange<Date> {
        Day.toLocal(period.start)...Day.toLocal(min(period.lastDay, store.today))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount (\(period.cap.currency.rawValue))", text: $amountText).keyboardType(.decimalPad)
                    DatePicker("Used on", selection: $date, in: localRange, displayedComponents: .date)
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
                        guard let amount = parsedAmount else { return }
                        if store.logUsage(periodID: period.id, amount: amount, usedOn: Day.fromLocal(date), note: note) {
                            dismiss()
                        } else {
                            saveFailed = true
                        }
                    }
                    .disabled(parsedAmount == nil)
                }
            }
            .onAppear {
                amountText = period.remaining.decimal.formatted(.number.precision(.fractionLength(2)).grouping(.never))
                let defaultDay = min(max(store.today, period.start), period.lastDay)
                date = Day.toLocal(defaultDay)
            }
            .alert("Check the amount and date, then try again", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            }
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
    @State private var issuedDate = Day.toLocal(Day.today)
    @State private var expiresDate = Day.toLocal(Day.today)
    @State private var redeemed = false
    @State private var redeemedOn = Day.toLocal(Day.today)

    private var isNew: Bool { !store.certificates.contains { $0.id == certificate.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Issued", selection: $issuedDate, displayedComponents: .date)
                    DatePicker("Expires", selection: $expiresDate, displayedComponents: .date)
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
                        c.issuedOn = Day.fromLocal(issuedDate)
                        c.expiresOn = Day.fromLocal(expiresDate)
                        c.redeemedOn = redeemed ? Day.fromLocal(redeemedOn) : nil
                        store.saveCertificate(c)
                        dismiss()
                    }
                    .disabled(Day.fromLocal(expiresDate) <= Day.fromLocal(issuedDate))
                }
            }
            .onAppear {
                issuedDate = Day.toLocal(certificate.issuedOn)
                expiresDate = Day.toLocal(certificate.expiresOn)
                redeemed = certificate.redeemedOn != nil
                redeemedOn = Day.toLocal(certificate.redeemedOn ?? store.today)
            }
        }
    }
}
