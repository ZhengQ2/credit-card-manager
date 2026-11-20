import SwiftUI

struct CardWatchlistView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WatchlistEntry?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if store.watchlist.isEmpty {
                    ContentUnavailableView("No watchlisted cards", systemImage: "bookmark",
                                           description: Text("Add a catalog card to compare its rewards in Best Card."))
                }
                ForEach(store.watchlist) { entry in
                    Button { draft = entry } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Catalog.exactProduct(entry.productID)?.displayName ?? "Card unavailable in catalog")
                                .foregroundStyle(.primary)
                            if !entry.note.isEmpty {
                                Text(entry.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            do { try store.removeWatchlistEntry(productID: entry.productID) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("Watchlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add card", systemImage: "plus") { draft = WatchlistEntry(productID: "", note: "") }
                }
            }
            .sheet(item: $draft) { WatchlistEntryEditor(entry: $0) }
            .alert("Could not update watchlist", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct WatchlistEntryEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: WatchlistEntry
    @State private var productID: String
    @State private var note: String
    @State private var errorMessage: String?

    init(entry: WatchlistEntry) {
        self.entry = entry
        _productID = State(initialValue: entry.productID)
        _note = State(initialValue: entry.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                let product = Catalog.exactProduct(productID)
                if entry.productID.isEmpty {
                    NavigationLink {
                        ProductListView(selection: $productID, market: nil,
                                        excludedProductIDs: Set(store.watchlist.map(\.productID)).union(["custom-us", "custom-ca"]))
                    } label: {
                        LabeledContent("Card", value: product?.displayName ?? "Choose a card")
                    }
                } else {
                    LabeledContent("Card", value: product?.displayName ?? "Unavailable in catalog")
                }
                TextField("Notes", text: $note, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle(entry.productID.isEmpty ? "Add to watchlist" : "Watchlist notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveWatchlistEntry(productID: productID, note: note)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(Catalog.exactProduct(productID) == nil)
                }
            }
            .alert("Could not save watchlist entry", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}
