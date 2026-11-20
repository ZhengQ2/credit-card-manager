import Foundation

struct WatchlistEntry: Identifiable, Codable, Equatable {
    let productID: String
    var note: String
    var id: String { productID }
}

enum WatchlistError: Error, LocalizedError {
    case unknownProduct

    var errorDescription: String? { "Choose a card from the current catalog." }
}

@MainActor
extension Store {
    private static let watchlistKey = "card_watchlist"

    func loadWatchlist(from repo: LedgerRepository) {
        let entries = repo.setting(Self.watchlistKey).flatMap {
            try? JSONDecoder().decode([WatchlistEntry].self, from: Data($0.utf8))
        } ?? []
        var seen: Set<String> = []
        watchlist = entries.filter { seen.insert($0.productID).inserted }
    }

    func saveWatchlistEntry(productID: String, note: String) throws {
        guard let product = Catalog.exactProduct(productID), product.issuer != "Other" else { throw WatchlistError.unknownProduct }
        let entry = WatchlistEntry(productID: productID, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        var entries = watchlist
        if let index = entries.firstIndex(where: { $0.productID == productID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persistWatchlist(entries)
    }

    func removeWatchlistEntry(productID: String) throws {
        try persistWatchlist(watchlist.filter { $0.productID != productID })
    }

    var watchlistRewards: RewardsEngine {
        // The projections are only used to quote hypothetical purchases with unused caps.
        let candidates = watchlist.compactMap { entry -> Card? in
            guard let product = Catalog.exactProduct(entry.productID) else { return nil }
            return Card(id: "watchlist:\(product.id)", nickname: product.displayName, productID: product.id,
                        mask: nil, openedOn: today, renewal: nil, connection: .manual, lastSync: nil, historyStart: today)
        }
        return RewardsEngine(cards: candidates, assumptions: assumptions)
    }

    private func persistWatchlist(_ entries: [WatchlistEntry]) throws {
        guard let repo else { throw DatabaseError.keyUnavailable }
        let data = try JSONEncoder().encode(entries)
        try repo.setSetting(Self.watchlistKey, entries.isEmpty ? nil : String(decoding: data, as: UTF8.self))
        watchlist = entries
    }
}
