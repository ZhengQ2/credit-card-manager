import SwiftUI

/// Displays the card's upcoming payment due date (from PDF/CSV statement import or Plaid)
/// and lets the owner mark a statement bill paid, change its due date, or remove the reminder.
struct StatementBillSection: View {
    @Environment(Store.self) private var store
    let card: Card

    @State private var editingDueDate = false
    @State private var dueDateDraft = Date()

    var body: some View {
        let stored = store.statementBill(for: card.id)
        let upcoming = store.upcomingBill(for: card.id)

        if stored != nil || upcoming != nil {
            Section {
                if let bill = stored, let due = bill.dueDate {
                    let days = Day.days(from: store.today, to: due)
                    LabeledContent("Payment due") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Day.format(due))
                                .fontWeight(.semibold)
                            if bill.isPaid {
                                Text("Marked paid")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if days == 0 {
                                Text("Due today")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                            } else if days > 0 {
                                Text("In \(days) day\(days == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(days <= 3 ? .orange : .secondary)
                            } else {
                                Text("\(-days) day\(-days == 1 ? "" : "s") past due")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    LabeledContent("Source", value: bill.source.rawValue)

                    Button {
                        store.markStatementBillPaid(!bill.isPaid, for: card.id)
                    } label: {
                        Label(
                            bill.isPaid ? "Mark unpaid" : "Mark as paid",
                            systemImage: bill.isPaid ? "arrow.uturn.backward.circle" : "checkmark.circle"
                        )
                    }

                    Button("Change due date") {
                        dueDateDraft = Day.toLocal(due)
                        editingDueDate = true
                    }
                    .font(.callout)

                    Button("Remove payment reminder", role: .destructive) {
                        store.removeStatementBill(for: card.id)
                    }
                    .font(.callout)
                } else if let upcoming {
                    let days = upcoming.daysUntilDue(from: store.today)
                    LabeledContent("Payment due") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Day.format(upcoming.dueDate))
                                .fontWeight(.semibold)
                            Text(days == 0 ? "Due today" : "In \(days) day\(days == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(days == 0 ? .red : (days <= 3 ? .orange : .secondary))
                        }
                    }
                    LabeledContent("Source", value: upcoming.origin.label)
                }

                if let msg = store.statementBillNotifications.message, stored?.isPaid == false {
                    Label(msg, systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Payment due")
            } footer: {
                if let bill = stored {
                    if bill.isPaid {
                        Text("Payment reminders for this due date are paused.")
                    } else {
                        Text("Local reminders fire at 9 AM, 3 days before and on the due date. Lock-screen messages omit card details.")
                    }
                } else {
                    Text("Synced from Plaid. Reminders fire at 9 AM, 3 days before and on the due date.")
                }
            }
            .sheet(isPresented: $editingDueDate) {
                NavigationStack {
                    Form {
                        DatePicker("Payment due", selection: $dueDateDraft, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }
                    .navigationTitle("Payment due date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editingDueDate = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let chosen = Day.fromLocal(dueDateDraft)
                                let source = stored?.source ?? .manual
                                let stmtDate = stored?.statementDate
                                editingDueDate = false
                                Task {
                                    await store.saveStatementBill(
                                        cardID: card.id,
                                        dueDate: chosen,
                                        statementDate: stmtDate,
                                        source: source,
                                        forceReplace: true
                                    )
                                }
                            }
                        }
                    }
                }
                .presentationDetents([.large])
            }
        }
    }
}
